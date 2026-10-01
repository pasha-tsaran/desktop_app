# Armenia recovery check

`tool/test-armenia-recovery.ps1` is an operator-run Windows PowerShell 5.1
diagnostic, not application or service code. Run elevated while the first
Kenai app is connected to Armenia. `-PreflightOnly` performs no mutation.

The test requires the exact installed first-app Xray process, an established
connection to Armenia TCP/443, an up KenaiXray adapter and a successful IPv4
exit check. It does not read profiles, restart services, change DNS/routes,
or touch the server or kill-switch configuration.

After arming an independent hidden cleanup process, it creates one randomly
named outbound firewall rule scoped to the installed first-app Xray path and
Armenia TCP/443. The main process removes it after 15 seconds in `finally`.
The independent process also attempts removal after 40 seconds, five times.
Do not shut down Windows during this short test: the firewall rule is a local
rule, not a crash-proof expiring Windows policy. Its exact name is printed.
If both processes are forcibly terminated, remove only that printed rule:
`Remove-NetFirewallRule -Name '<exact TEMPORARY_RULE value>'` as administrator.

No public probe is sent during the interruption; this is not a kill-switch
or leak test. After removal, up to four bounded IPv4 requests check recovery
and require the Armenia exit IP, not merely an HTTP response. A firewall
block window alone does not prove that every existing flow was interrupted.
Observe the GUI separately; successful recovery does not validate GUI status.

If automatic recovery fails after `CLEANUP_CONFIRMED=True`, use Disconnect
and Connect in the first app. No saved credentials are changed by this test.
Do not claim success until the live operator-run result is available.
