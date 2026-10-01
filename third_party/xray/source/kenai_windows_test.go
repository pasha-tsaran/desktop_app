//go:build windows

package tun

import (
	"net/netip"
	"os"
	"testing"
	"golang.org/x/sys/windows"
)

func TestKenaiFamilyRequested(t *testing.T) {
	v4dns := []netip.Addr{netip.MustParseAddr("1.1.1.1")}
	if kenaiFamilyRequested(false, false, v4dns, true) {
		t.Fatal("IPv4-only configuration must not touch disabled IPv6")
	}
	if !kenaiFamilyRequested(true, false, nil, true) ||
		!kenaiFamilyRequested(false, true, nil, true) ||
		!kenaiFamilyRequested(false, false, []netip.Addr{netip.MustParseAddr("::1")}, true) {
		t.Fatal("explicit IPv6 configuration must still configure IPv6")
	}
	if !kenaiFamilyRequested(false, false, v4dns, false) {
		t.Fatal("IPv4 DNS must be configured")
	}
}

// Explicit opt-in integration test. No default routes, keys or remote server.
func TestKenaiNativeIPv4Tun(t *testing.T) {
	if os.Getenv("KENAI_NATIVE_TEST") != "1" { t.Skip("requires Windows elevation") }
	device, err := NewTun(&Config{
		Name: "KenaiXraySelfTest", Desc: "Kenai test", MTU: 1500,
		Gateway: []string{"198.18.0.1/30"},
		AutoSystemRoutingTable: []string{"198.18.0.2/32"},
	})
	if err != nil { t.Fatal(err) }
	defer device.Close()
	if err := device.Start(); err != nil { t.Fatal(err) }
	windowsTun := device.(*WindowsTun)
	if _, err := windowsTun.luid.IPInterface(windows.AF_INET); err != nil { t.Fatal(err) }
	if _, err := device.Index(); err != nil { t.Fatal(err) }
}
