package main

import (
	"fmt"
	"os"
	"os/exec"
)

// runScript writes body to a temp file with the given extension and runs it
// via interpreter (e.g. []string{"sh"} or []string{"powershell", "-NoProfile",
// "-ExecutionPolicy", "Bypass", "-File"}), returning combined output on
// failure for diagnostics.
func runScript(interpreter []string, body, ext string) error {
	f, err := os.CreateTemp("", "mcvpn-tun-*"+ext)
	if err != nil {
		return err
	}
	path := f.Name()
	defer os.Remove(path)

	if _, err := f.WriteString(body); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}

	args := append(append([]string{}, interpreter[1:]...), path)
	out, err := exec.Command(interpreter[0], args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, string(out))
	}
	return nil
}
