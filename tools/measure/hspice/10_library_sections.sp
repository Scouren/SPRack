* #56 item 10: the deck asks for section one only. Read: loads (i(v1) 1 mA)
* or stops on no_such_file.inc.
.lib '10_library_sections.lib' one
v1 a 0 1
r1 a 0 rv
.op
.print op i(v1)
.end
