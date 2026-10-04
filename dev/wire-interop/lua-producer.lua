local json = require("lunajson")
local document = {
    schema = "libtmux.julia.where",
    version = 1,
    entity = "pane",
    where = {
        op = "fields",
        fields = {
            { field = "tmux.pane.active", match = { op = "eq", value = false } },
        },
    },
}
io.write(json.encode(document), "\n")
