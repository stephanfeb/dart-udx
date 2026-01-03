/// Logging infrastructure for dart-udx
/// 
/// Provides a configurable logging system to replace direct print statements.
/// Applications can set a custom logger and control verbosity.

/// Type definition for a logger function
typedef UdxLogger = void Function(String level, String message);

/// Centralized logging for dart-udx
class UdxLogging {
  /// The logger function to use. If null, logging is disabled.
  static UdxLogger? logger;
  
  /// Whether to enable verbose/debug logging
  static bool verbose = false;
  
  /// Whether to enable info-level logging
  static bool info = false;
  
  /// Log a debug message (only if verbose is true)
  static void debug(String message) {
    if (verbose && logger != null) {
      logger!('DEBUG', message);
    }
  }
  
  /// Log an info message (only if info is true)
  static void infoLog(String message) {
    if (info && logger != null) {
      logger!('INFO', message);
    }
  }
  
  /// Log a warning message (always logged if logger is set)
  static void warn(String message) {
    logger?.call('WARN', message);
  }
  
  /// Log an error message (always logged if logger is set)
  static void error(String message) {
    logger?.call('ERROR', message);
  }
  
  /// Set a simple print-based logger
  static void setDefaultLogger() {
    logger = (level, message) => print('[$level] $message');
  }
}

