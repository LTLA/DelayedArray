### =========================================================================
### Write array blocks
### -------------------------------------------------------------------------


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### write_block()
###

### 'sink' must be a **writable** array-like object, typically a
### RealizationSink concrete subclass. We also make write_block() work
### on ordinary arrays or other in-memory array-like objects (e.g.
### sparseMatrix derivatives from the Matrix package) by defining
### the default method below.
### For now dispatch is only on the first argument ('sink') but we
### could change this in the future to also dispatch on the third
### argument ('block') when the need arises.
### Must return 'sink' (possibly modified if it's an in-memory object).
setGeneric("write_block", signature="sink",
    function(sink, viewport, block)
    {
        stopifnot(is(viewport, "ArrayViewport"),
                  identical(refdim(viewport), dim(sink)),
                  identical(dim(block), dim(viewport)))
        standardGeneric("write_block")
    }
)

### Work on any array-like object that supports '[<-'.
setMethod("write_block", "ANY",
    function(sink, viewport, block)
    {
        if (is(block, "SparseArraySeed"))
            block <- sparse2dense(block)
        Nindex <- makeNindexFromArrayViewport(viewport)
        replace_by_Nindex(sink, Nindex, block)
    }
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### RealizationSink objects
###
### Virtual class with no slots. Intended to be extended to support specific
### realization backends. Concrete subclasses must implement the "sink
### contract", that is:
###   1) A constructor function where the first 3 arguments are 'dim',
###      'dimnames', and 'type', in that order. Optionally it can have
###      the 'as.sparse' argument, in which case this **must** be the 4th
###      argument. It can have any additional argument.
###   2) A dim(), dimnames(), and type() method.
###   3) A write_block() method. It must return the modified array-like
###      object 'sink'.
###   4) A close() method (optional).
###   5) Coercion to DelayedArray.
###
### Examples of RealizationSink concrete subclasses: arrayRealizationSink
### (see below), RleRealizationSink (see RleArray-class.R),
### HDF5RealizationSink and TENxRealizationSink (see HDF5Array package).

setClass("RealizationSink", representation("VIRTUAL"))

setGeneric("close")

### The default "close" method for RealizationSink objects is a no-op.
setMethod("close", "RealizationSink", function(con) invisible(NULL))


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### arrayRealizationSink objects
###
### The arrayRealizationSink class is a concrete RealizationSink subclass that
### implements an in-memory realization sink.
###

setClass("arrayRealizationSink",
    contains="RealizationSink",
    representation(
        result_envir="environment"
    )
)

.get_arrayRealizationSink_result <- function(sink)
{
    get("result", envir=sink@result_envir)
}

.set_arrayRealizationSink_result <- function(sink, result)
{
    assign("result", result, envir=sink@result_envir)
}

setMethod("dim", "arrayRealizationSink",
    function(x) dim(.get_arrayRealizationSink_result(x))
)

arrayRealizationSink <- function(dim, dimnames=NULL, type="double")
{
    result <- array(get(type)(0), dim=dim, dimnames=dimnames)
    result_envir <- new.env(parent=emptyenv())
    sink <- new("arrayRealizationSink", result_envir=result_envir)
    .set_arrayRealizationSink_result(sink, result)
    sink
}

setMethod("write_block", "arrayRealizationSink",
    function(sink, viewport, block)
    {
        result <- .get_arrayRealizationSink_result(sink)
        result <- write_block(result, viewport, block)
        .set_arrayRealizationSink_result(sink, result)
    }
)

setAs("arrayRealizationSink", "DelayedArray",
    function(from) DelayedArray(.get_arrayRealizationSink_result(from))
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Get/set the "realization backend" for the current session
###

.auto_realization_backend_envir <- new.env(parent=emptyenv())

getAutoRealizationBackend <- function()
{
    get_user_option("auto.realization.backend")
}

getRealizationBackend <- function()
{
    .Deprecated("getAutoRealizationBackend")
    getAutoRealizationBackend()
}

.SUPPORTED_REALIZATION_BACKENDS <- data.frame(
    BACKEND=c("RleArray", "HDF5Array", "TENxMatrix"),
    package=c("DelayedArray", "HDF5Array", "HDF5Array"),
    realization_sink_class=c("RleRealizationSink",
                             "HDF5RealizationSink",
                             "TENxRealizationSink"),
    stringsAsFactors=FALSE
)

supportedRealizationBackends <- function()
{
    ans <- .SUPPORTED_REALIZATION_BACKENDS[ , c("BACKEND", "package")]
    backend <- getAutoRealizationBackend()
    Lcol <- ifelse(ans[ , "BACKEND"] %in% backend, "->", "")
    Rcol <- ifelse(ans[ , "BACKEND"] %in% backend, "<-", "")
    cbind(data.frame(` `=Lcol, check.names=FALSE),
          ans,
          data.frame(` `=Rcol, check.names=FALSE))
}

### NOT exported.
load_BACKEND_package <- function(BACKEND)
{
    if (!isSingleString(BACKEND))
        stop(wmsg("'BACKEND' must be a single string or NULL"))
    backends <- .SUPPORTED_REALIZATION_BACKENDS
    m <- match(BACKEND, backends[ , "BACKEND"])
    if (is.na(m))
        stop(wmsg("\"", BACKEND, "\" is not a supported backend. Please ",
                  "use supportedRealizationBackends() to get the list of ",
                  "\"realization backends\" that are currently supported."))
    package <- backends[ , "package"][[m]]
    class_package <- attr(BACKEND, "package")
    if (is.null(class_package)) {
        attr(BACKEND, "package") <- package
    } else if (!identical(package, class_package)) {
        stop(wmsg("\"package\" attribute on supplied 'BACKEND' is ",
                  "inconsistent with package normally associated with ",
                  "this backend"))
    }
    library(package, character.only=TRUE)
    stopifnot(getClass(BACKEND)@package == package)
}

.check_realization_sink_constructor <- function(realization_sink_constructor)
{
    stopifnot(is.function(realization_sink_constructor))
    ok <- identical(head(formalArgs(realization_sink_constructor), n=3L),
                    c("dim", "dimnames", "type"))
    if (!ok)
        stop(wmsg("the first 3 arguments of a RealizationSink constructor ",
                  "function must be 'dim', 'dimnames', and 'type', in ",
                  "that order"))
    ## Either 'realization_sink_constructor' has the 'as.sparse' argument,
    ## in which case it **must** be in 4th position, or it does not have it.
    m <- match("as.sparse", formalArgs(realization_sink_constructor))
    if (!(m %in% c(4L, NA_integer_)))
        stop(wmsg("RealizationSink constructor functions with an 'as.sparse' ",
                  "argument must have it in 4th position"))
}

.get_realization_sink_constructor <- function(BACKEND)
{
    backends <- .SUPPORTED_REALIZATION_BACKENDS
    m <- match(BACKEND, backends[ , "BACKEND"])
    realization_sink_class <- backends[ , "realization_sink_class"][[m]]
    package <- backends[ , "package"][[m]]
    realization_sink_constructor <- get(realization_sink_class,
                                        envir=.getNamespace(package),
                                        inherits=FALSE)
    .check_realization_sink_constructor(realization_sink_constructor)
    realization_sink_constructor
}

setAutoRealizationBackend <- function(BACKEND=NULL)
{
    if (is.null(BACKEND)) {
        remove(list=ls(envir=.auto_realization_backend_envir),
               envir=.auto_realization_backend_envir)
    } else {
        load_BACKEND_package(BACKEND)
        auto_realization_sink_constructor <-
            .get_realization_sink_constructor(BACKEND)
        assign("AUTO_REALIZATION_SINK_CONSTRUCTOR",
               auto_realization_sink_constructor,
               envir=.auto_realization_backend_envir)
    }
    set_user_option("auto.realization.backend", BACKEND)
    return(invisible(NULL))
}

setRealizationBackend <- function(...)
{
    .Deprecated("setAutoRealizationBackend")
    setAutoRealizationBackend(...)
}


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Backend-agnostic RealizationSink constructor
###

.get_auto_realization_sink_constructor <- function()
{
    if (is.null(getAutoRealizationBackend()))
        return(arrayRealizationSink)
    auto_realization_sink_constructor <-
        try(get("AUTO_REALIZATION_SINK_CONSTRUCTOR",
                envir=.auto_realization_backend_envir),
                silent=TRUE)
    if (is(auto_realization_sink_constructor, "try-error"))
        stop(wmsg("This operation requires a \"realization backend\". ",
                  "Please see '?setAutoRealizationBackend' for how ",
                  "to set one."))
    auto_realization_sink_constructor
}

AutoRealizationSink <- function(dim, dimnames=NULL, type="double",
                                as.sparse=FALSE)
{
    realization_sink_constructor <- .get_auto_realization_sink_constructor()
    args <- list(dim, dimnames, type)
    formal_args <- formalArgs(realization_sink_constructor)
    if (length(formal_args) >= 4L && formal_args[[4L]] == "as.sparse")
        args <- c(args, list(as.sparse=as.sparse))
    do.call(realization_sink_constructor, args)
}

RealizationSink <- function(...)
{
    .Deprecated("AutoRealizationSink")
    AutoRealizationSink(...)
}

