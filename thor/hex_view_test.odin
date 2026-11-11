package thor

import "core:testing"

@(test)
test_hex_row_text :: proc(t: ^testing.T) {
    bytes := []u8{'A', 0, 0xff, 'z', 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 'Q'}
    testing.expect_value(t, hex_row_text(bytes, 0), "00000000  41 00 ff 7a 01 02 03 04  05 06 07 08 09 0a 0b 0c  A..z............")
    // A short last row pads the hex block so the ASCII block stays aligned.
    row := hex_row_text(bytes, 1)
    testing.expect_value(t, len(row), HEX_COL_ASCII + 1)
    testing.expect_value(t, row[HEX_COL_ASCII:], "Q")
    testing.expect_value(t, row[:12], "00000010  51")
}

@(test)
test_hex_byte_at_col :: proc(t: ^testing.T) {
    for i in 0 ..< HEX_ROW_BYTES {
        for d in 0 ..< 2 {
            index, ok := hex_byte_at_col(hex_byte_col(i) + d)
            testing.expect(t, ok && index == i, "hex cell must map back to its byte")
        }
        index, ok := hex_byte_at_col(HEX_COL_ASCII + i)
        testing.expect(t, ok && index == i, "ascii cell must map back to its byte")
    }
    _, ok := hex_byte_at_col(0)
    testing.expect(t, !ok, "the offset column holds no byte")
    _, ok = hex_byte_at_col(HEX_COLS)
    testing.expect(t, !ok, "past the ASCII block holds no byte")
}

@(test)
test_hex_selection_text :: proc(t: ^testing.T) {
    bytes := []u8{0x00, 0xab, 0x10}
    testing.expect_value(t, hex_selection_text(bytes, 0, 2), "00 ab 10")
    testing.expect_value(t, hex_selection_text(bytes, 1, 1), "ab")
    testing.expect_value(t, hex_selection_text(bytes, 2, 5), "")
}
