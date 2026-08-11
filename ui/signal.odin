package ui

Signal :: struct($T: typeid) {
    value:         T,
    on_change:     proc(data: rawptr, value: T),
    listener_data: rawptr,
}

make_signal :: proc(value: $T) -> Signal(T) {
    return Signal(T) {
        value = value,
    }
}

signal_get :: proc(signal: ^Signal($T)) -> T {
    return signal.value
}

// Sets the listener signal_set calls after the value changes. One slot; call
// once at setup, not per-frame.
signal_set_listener :: proc(signal: ^Signal($T), on_change: proc(data: rawptr, value: T), data: rawptr) {
    signal.on_change = on_change
    signal.listener_data = data
}

signal_set :: proc(signal: ^Signal($T), value: T) {
    signal.value = value
    if signal.on_change != nil {
        signal.on_change(signal.listener_data, value)
    }
}
