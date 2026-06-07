"""Synthetic .d2s save crafting for tests.

realmd reads the class byte at offset 0x28 and the level at 0x2b out of the
raw save blob (see d2cs.zig onCharList). We don't need a real save — just a
plausible blob with the right header signature and those two fields placed
correctly, so a SAVE can be listed back with the expected class+level.
"""
import struct


D2S_SIGNATURE = 0xAA55AA55  # at offset 0


def minimal_d2s(name, class_id, level):
    """Build a minimal plausible .d2s blob.

      [0..4)   signature 0xAA55AA55
      [0x28]   class byte
      [0x2b]   level byte
    Padded to 0x40 bytes.
    """
    size = 0x40
    buf = bytearray(size)
    struct.pack_into("<I", buf, 0, D2S_SIGNATURE)
    # Name (16-byte field at 0x14 in a real save; harmless filler for us).
    nb = name.encode("latin1")[:15]
    buf[0x14:0x14 + len(nb)] = nb
    buf[0x28] = class_id & 0xFF
    buf[0x2b] = level & 0xFF
    return bytes(buf)
