# Mustache templates for Juango (`Juango.MustacheTemplates` in TEMPLATES): loaded with `using Mustache`.
module JuangoMustacheExt

import Juango
import Mustache

Juango.mustache_compile(src::AbstractString) = Mustache.parse(src)
Juango.mustache_render(tokens, ctx::AbstractDict) = Mustache.render(tokens, ctx)

end
