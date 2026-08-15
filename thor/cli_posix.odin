#+build !windows
package thor

// A POSIX binary shares the terminal of the shell that started it, so there is
// nothing to attach.
cli_attach_console :: proc() {
}
