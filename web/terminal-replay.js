// xterm writes asynchronously. Keep reply forwarding disabled until all
// historical bytes are parsed; live writes queued afterward remain interactive.
class TerminalReplay {
  active = false;
  write(terminal, chunks) {
    if (!chunks.length) return;
    this.active = true;
    const disabled = terminal.options.disableStdin;
    terminal.options.disableStdin = true;
    chunks.forEach(chunk => terminal.write(chunk));
    // Cancel a partially retained control sequence at the scrollback boundary.
    terminal.write('\x18', () => {
      this.active = false;
      terminal.options.disableStdin = disabled;
    });
  }
}
if (typeof module !== 'undefined') module.exports = { TerminalReplay };
