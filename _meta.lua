local _ = require("gettext")
local V = require("opds_store_version")
return {
    name = "opds_store",
    fullname = _("OPDS Store"),
    version = V.VERSION,
    description = _([[OPDS catalog browser with book cover display support. Browse and download books from online catalogs with visual cover previews in list or grid view.]]),
}
