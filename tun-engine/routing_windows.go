//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"strings"
)

func defaultGateway() (gateway, iface string, err error) {
	// Get-NetRoute prints one CSV line "NextHop,InterfaceAlias" for the
	// lowest-metric IPv4 default route.
	script := `$r = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 | Sort-Object -Property RouteMetric | Select-Object -First 1
Write-Output ($r.NextHop + "," + $r.InterfaceAlias)
`
	out, err := runPowerShellOutput(script)
	if err != nil {
		return "", "", err
	}
	parts := strings.SplitN(strings.TrimSpace(out), ",", 2)
	if len(parts) != 2 || parts[0] == "" {
		return "", "", fmt.Errorf("could not parse default route from: %q", out)
	}
	return parts[0], parts[1], nil
}

func applyRouting(cfg routingConfig) error {
	body := fmt.Sprintf(`$ErrorActionPreference = "Stop"
New-NetIPAddress -InterfaceAlias "%s" -IPAddress %s -PrefixLength %d | Out-Null
route add %s mask 255.255.255.255 %s metric 1 | Out-Null
route add 0.0.0.0 mask 128.0.0.0 %s metric 1 | Out-Null
route add 128.0.0.0 mask 128.0.0.0 %s metric 1 | Out-Null
`,
		cfg.TunName, cfg.TunIP, cfg.TunBits,
		cfg.ExcludeIP, cfg.Gateway,
		cfg.TunIP,
		cfg.TunIP,
	)
	return runScript(powershellInterpreter, body, ".ps1")
}

func revertRouting(cfg routingConfig) error {
	body := fmt.Sprintf(`route delete %s | Out-Null
route delete 0.0.0.0 mask 128.0.0.0 | Out-Null
route delete 128.0.0.0 mask 128.0.0.0 | Out-Null
`, cfg.ExcludeIP)
	return runScript(powershellInterpreter, body, ".ps1")
}

var powershellInterpreter = []string{"powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"}

func runPowerShellOutput(script string) (string, error) {
	out, err := exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script).CombinedOutput()
	return string(out), err
}
