///|
#deprecated("use `==` and `!=`", skip_current_package=true)
#doc(hidden)
pub extend Point with Eq::{equal, not_equal}

///|
#deprecated("reach it through the `Debug` bound", skip_current_package=true)
#doc(hidden)
pub extend Point with @debug.Debug::{to_repr}

///|
#deprecated("use `==` and `!=`", skip_current_package=true)
#doc(hidden)
pub extend Config with Eq::{equal, not_equal}

///|
#deprecated("reach it through the `Debug` bound", skip_current_package=true)
#doc(hidden)
pub extend Config with @debug.Debug::{to_repr}

///|
#deprecated("use `==` and `!=`", skip_current_package=true)
#doc(hidden)
pub extend Shape with Eq::{equal, not_equal}

///|
#deprecated("reach it through the `Debug` bound", skip_current_package=true)
#doc(hidden)
pub extend Shape with @debug.Debug::{to_repr}

///|
#deprecated("use `==` and `!=`", skip_current_package=true)
#doc(hidden)
pub extend Pair with Eq::{equal, not_equal}

///|
#deprecated("reach it through the `Debug` bound", skip_current_package=true)
#doc(hidden)
pub extend Pair with @debug.Debug::{to_repr}

///|
#deprecated("use `==` and `!=`", skip_current_package=true)
#doc(hidden)
pub extend Rgb with Eq::{equal, not_equal}

///|
#deprecated("reach it through the `Debug` bound", skip_current_package=true)
#doc(hidden)
pub extend Rgb with @debug.Debug::{to_repr}

///|
#deprecated("use `==` and `!=`", skip_current_package=true)
#doc(hidden)
pub extend Meters with Eq::{equal, not_equal}

///|
#deprecated("reach it through the `Debug` bound", skip_current_package=true)
#doc(hidden)
pub extend Meters with @debug.Debug::{to_repr}

///|
#deprecated("use `==` and `!=`", skip_current_package=true)
#doc(hidden)
pub extend Marker with Eq::{equal, not_equal}

///|
#deprecated("reach it through the `Debug` bound", skip_current_package=true)
#doc(hidden)
pub extend Marker with @debug.Debug::{to_repr}
