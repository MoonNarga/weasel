# Candidate UI regression checks

Build `WeaselTSF` in MSBuild Release/x64 first. From an x64 Visual Studio
Developer Command Prompt, set `BOOST_ROOT` to the same Boost tree (static runtime
libraries in `stage/lib`) and run `test\TestCandidateUI\run.cmd`.

The test links the actual TSF and UI objects. It runs under an ordinary executable
name, then as a separate test executable named `dota2.exe` to exercise process
detection. It verifies candidate data, a visible nonempty native window, startup
idempotence, destruction/recreation, full cleanup, the default position inside
the host window, rejection of zero/nonzero dummy and out-of-bounds extents,
failed `GetTextExt`, genuine TSF/Win32/IMM coordinates, and a moved/resized host.
It does not launch or
send input to the real game. The candidate test window appears briefly.

Optional local integration check, with an installed WeaselServer running:

```text
output\local-tests\candidate-ui\TestCandidateUI.exe --ipc
```

This opens and closes an empty IPC session and verifies that the installed
server's serialized style can be read by the newly built client.

## Dota 2 manual verification

The compatibility path uses Weasel's own candidate window for `dota2.exe`.
When the game supplies no usable text extent, the window initially appears
one quarter across and three quarters down its client area. This is a fallback
position, not a measurement of Dota's chat caret. Positioning runs after layout
updates. A valid TSF text extent takes priority, followed by a Win32 caret and
explicit IMM candidate/composition positions. These additional sources help
only when the game supplies them. Zero-sized IME helper windows are excluded
when resolving the game window.

For a local diagnosis, set the DWORD `TraceDotaPosition` to `1` under
`HKCU\Software\Rime\Weasel` before starting the game. The first 256 positioning
events per input thread are logged in `%TEMP%\rime.weasel\dota2-position-PID.log`.
Entries include raw `GetTextExt` results, the chosen coordinate source, and the
chosen rectangle. No typed text or candidate strings are logged. `E_PENDING`
means no text extent has been supplied for that composition yet. Set the DWORD
to `0` or delete it and restart the game to disable tracing.

After installing the rebuilt x64 TSF DLL, restart Dota 2. In windowed or borderless
mode, open chat, switch to Chinese, type without sending the message, select a
candidate, cancel/reopen chat, and switch focus away and back. Check candidates
and the configured background, and repeat in a normal desktop editor.
Exclusive fullscreen rendering is not covered by this desktop-window approach.

The game-side compatibility-table limitation is also described in
[ValveSoftware/Dota2-Gameplay discussion 33909](https://github.com/ValveSoftware/Dota2-Gameplay/discussions/33909).
That report concerns a different IME and is supporting evidence, not an
end-to-end test of Weasel in Dota 2.
