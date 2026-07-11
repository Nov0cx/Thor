package ui

Signal :: struct($T: typeid) {
    value: T,
}

make_signal :: proc(value: $T) -> Signal(T) {
    return Signal(T) {
        value = value,
    }
}

signal_get :: proc(signal: ^Signal($T)) -> T {
    return signal.value
}

signal_set :: proc(signal: ^Signal($T), value: T) {
    signal.value = value
}
