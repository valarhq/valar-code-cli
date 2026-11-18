// A stand-in valar for the installer tests, which tests/prepare.sh builds for every target.
// `valar setup` writes how it ran to $STUB_LOG and exits $STUB_SETUP_EXIT; with STUB_NO_SETUP=1
// it is a release without `setup`.
package main

import (
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
)

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		return
	}
	switch args[0] {
	case "--version":
		fmt.Println("valar valar-cli-v0.0.0-stub")
	case "setup":
		if slices.Contains(args, "--help") {
			if os.Getenv("STUB_NO_SETUP") == "1" {
				fmt.Fprintln(os.Stderr, `Error: unknown command "setup" for "valar"`)
				os.Exit(1)
			}
			return
		}
		stdin := "not a terminal"
		if fi, err := os.Stdin.Stat(); err == nil && fi.Mode()&os.ModeCharDevice != 0 {
			stdin = "terminal"
		}
		if log := os.Getenv("STUB_LOG"); log != "" {
			_ = os.WriteFile(log, []byte("args: "+strings.Join(args, " ")+"\nstdin: "+stdin+"\n"), 0o644)
		}
		code, _ := strconv.Atoi(os.Getenv("STUB_SETUP_EXIT"))
		os.Exit(code)
	}
}
