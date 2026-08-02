// Command tun-engine is mcvpn's whole-device TUN helper for desktop
// platforms (Windows, Linux). It creates a TUN interface, points a
// tun2socks engine (github.com/xjasonlyu/tun2socks/v2) at the Flutter app's
// local SOCKS5 proxy, and adjusts the OS routing table so all traffic goes
// through the tunnel except the one connection that must stay off it: the
// Minecraft socket carrying the tunnel itself (otherwise it would route
// into itself and deadlock, the same problem Android's VpnService.Builder
// .addDisallowedApplication solves at the app level -- there's no per-app
// exclusion primitive on desktop, so instead we exclude the mc server's IP
// via a host route through the original gateway).
//
// This binary needs elevated privileges (root on Linux, Administrator on
// Windows) to create a TUN device and edit routes -- the caller is
// responsible for launching it elevated (pkexec / "Start-Process -Verb
// RunAs"), not this binary.
//
// Synchronization is file-based, not stdio-based: on Windows, a process
// launched elevated via "Start-Process -Verb RunAs" runs in a new session
// and does NOT inherit the parent's stdio pipes, so a caller across that
// boundary can't read our stdout or deliver Ctrl+C. Two optional flags
// carry status and control instead:
//
//	-status-file <path>  we write "MCVPN_TUN_READY" or
//	                      "MCVPN_TUN_ERROR: <message>" here (as well as to
//	                      stdout, which still works for direct/non-elevated
//	                      invocations and manual debugging)
//	-stop-file <path>     we poll for this file; its appearance is a
//	                      shutdown request, and we delete it once seen
//
// We also shut down on SIGINT/SIGTERM or stdin EOF for the common case
// where the caller *can* use ordinary process control (Linux via pkexec,
// or direct unelevated runs).
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/xjasonlyu/tun2socks/v2/engine"
)

var statusFile string

func main() {
	device := flag.String("device", "mcvpn0", "TUN device/adapter name")
	proxyAddr := flag.String("proxy", "127.0.0.1:1080", "upstream SOCKS5 host:port")
	mtu := flag.Int("mtu", 1500, "TUN MTU")
	tunIP := flag.String("tun-ip", "10.10.10.2", "TUN interface address")
	tunBits := flag.Int("tun-bits", 24, "TUN interface prefix length")
	excludeIP := flag.String("exclude-ip", "", "IP to keep routed via the original gateway (the mc server) -- required unless -no-route")
	noRoute := flag.Bool("no-route", false, "bring the TUN device up without touching the system routing table (diagnostics only)")
	statusFileFlag := flag.String("status-file", "", "also write MCVPN_TUN_READY / MCVPN_TUN_ERROR here")
	stopFileFlag := flag.String("stop-file", "", "poll for this file; its appearance is a shutdown request")
	flag.Parse()
	statusFile = *statusFileFlag

	if *excludeIP == "" && !*noRoute {
		fail("exclude-ip is required unless -no-route")
	}

	var rt *appliedRouting
	if !*noRoute {
		gw, iface, err := defaultGateway()
		if err != nil {
			fail("could not determine current default gateway: %v", err)
		}
		cfg := routingConfig{
			TunName:      *device,
			TunIP:        *tunIP,
			TunBits:      *tunBits,
			ExcludeIP:    *excludeIP,
			Gateway:      gw,
			GatewayIface: iface,
		}
		if err := applyRouting(cfg); err != nil {
			fail("failed to apply routing: %v", err)
		}
		rt = &appliedRouting{cfg: cfg}
	}

	key := &engine.Key{
		MTU:    *mtu,
		Device: "tun://" + *device,
		Proxy:  "socks5://" + *proxyAddr,
	}
	engine.Insert(key)
	engine.Start()

	reportReady()

	shutdown := make(chan struct{})
	var once sync.Once
	trigger := func() { once.Do(func() { close(shutdown) }) }

	go watchStdin(trigger)
	if *stopFileFlag != "" {
		go watchStopFile(*stopFileFlag, trigger)
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)

	select {
	case <-sigs:
	case <-shutdown:
	}

	engine.Stop()
	if rt != nil {
		_ = revertRouting(rt.cfg) // best effort; nothing left to report to once we're exiting
	}
}

// watchStdin triggers shutdown once stdin hits EOF or errors, i.e. the
// parent process closed or died -- catches the case where we're killed
// hard enough to skip signal delivery. A no-op (blocks forever) if stdin
// isn't connected to a pipe, which is fine: the stop-file / signal paths
// still work.
func watchStdin(trigger func()) {
	r := bufio.NewReader(os.Stdin)
	for {
		if _, err := r.ReadByte(); err != nil {
			trigger()
			return
		}
	}
}

// watchStopFile polls for path's existence as a caller-independent shutdown
// signal -- see the package doc comment for why stdio/signals alone aren't
// enough on Windows.
func watchStopFile(path string, trigger func()) {
	t := time.NewTicker(300 * time.Millisecond)
	defer t.Stop()
	for range t.C {
		if _, err := os.Stat(path); err == nil {
			_ = os.Remove(path)
			trigger()
			return
		}
	}
}

func reportReady() {
	fmt.Println("MCVPN_TUN_READY")
	os.Stdout.Sync()
	writeStatusFile("MCVPN_TUN_READY\n")
}

func fail(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	fmt.Println("MCVPN_TUN_ERROR: " + msg)
	writeStatusFile("MCVPN_TUN_ERROR: " + msg + "\n")
	os.Exit(1)
}

func writeStatusFile(content string) {
	if statusFile == "" {
		return
	}
	_ = os.WriteFile(statusFile, []byte(content), 0o644)
}

type routingConfig struct {
	TunName      string
	TunIP        string
	TunBits      int
	ExcludeIP    string
	Gateway      string
	GatewayIface string
}

type appliedRouting struct {
	cfg routingConfig
}
