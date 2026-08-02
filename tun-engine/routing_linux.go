//go:build linux

package main

import (
	"fmt"
	"os/exec"
	"regexp"
)

var defaultRouteRE = regexp.MustCompile(`^default via (\S+) dev (\S+)`)

func defaultGateway() (gateway, iface string, err error) {
	out, err := exec.Command("ip", "route", "show", "default").Output()
	if err != nil {
		return "", "", err
	}
	m := defaultRouteRE.FindStringSubmatch(string(out))
	if m == nil {
		return "", "", fmt.Errorf("no default route found in: %q", out)
	}
	return m[1], m[2], nil
}

func applyRouting(cfg routingConfig) error {
	body := fmt.Sprintf(`set -e
ip link set dev %s up
ip addr add %s/%d dev %s
ip route add %s/32 via %s dev %s
ip route add 0.0.0.0/1 dev %s
ip route add 128.0.0.0/1 dev %s
`,
		cfg.TunName,
		cfg.TunIP, cfg.TunBits, cfg.TunName,
		cfg.ExcludeIP, cfg.Gateway, cfg.GatewayIface,
		cfg.TunName,
		cfg.TunName,
	)
	return runScript([]string{"sh"}, body, ".sh")
}

func revertRouting(cfg routingConfig) error {
	body := fmt.Sprintf(`ip route del %s/32 via %s dev %s 2>/dev/null || true
ip route del 0.0.0.0/1 dev %s 2>/dev/null || true
ip route del 128.0.0.0/1 dev %s 2>/dev/null || true
`,
		cfg.ExcludeIP, cfg.Gateway, cfg.GatewayIface,
		cfg.TunName,
		cfg.TunName,
	)
	return runScript([]string{"sh"}, body, ".sh")
}
