module PopulationCartogramProjectionMetalExt

using Metal
import PopulationCartogramProjection:
    _optional_backend_functional,
    _optional_backend_loaded,
    _optional_ka_backend

_optional_backend_loaded(::Val{:metal}) = true
_optional_backend_functional(::Val{:metal}) = Metal.functional()
_optional_ka_backend(::Val{:metal}) = Metal.MetalBackend()

end
