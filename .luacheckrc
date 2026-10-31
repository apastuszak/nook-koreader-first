-- Static checks for the KOReader plugin (run by `make check`).
std = "luajit"
-- KOReader methods often take `self` or callback arguments they do not use.
self = false
unused_args = false
max_line_length = 140
-- KOReader's global settings object.
read_globals = { "G_reader_settings" }
