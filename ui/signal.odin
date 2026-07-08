package ui

Signal :: struct($T: typeid) {
    value:   T,
    version: u64,
}

Signal_Watcher :: struct {
    version: u64,
}

make_signal :: proc(value: $T) -> Signal(T) {
    return Signal(T) {
        value = value,
        version = 1,
    }
}

signal_get :: proc(signal: ^Signal($T)) -> T {
    return signal.value
}

signal_set :: proc(signal: ^Signal($T), value: T) {
    signal.value = value
    signal.version += 1
}

signal_watch :: proc(signal: ^Signal($T)) -> Signal_Watcher {
    return Signal_Watcher {
        version = signal.version,
    }
}

signal_changed :: proc(signal: ^Signal($T), watcher: ^Signal_Watcher) -> bool {
    if signal.version == watcher.version {
        return false
    }

    watcher.version = signal.version
    return true
}
