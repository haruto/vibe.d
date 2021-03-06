/**
	Central logging facility for vibe.

	Copyright: © 2012-2013 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.log;

import vibe.core.concurrency;
import vibe.core.sync;

import std.algorithm;
import std.array;
import std.datetime;
import std.format;
import std.stdio;
import core.thread;

/// Sets the minimum log level to be printed.
void setLogLevel(LogLevel level) nothrow
{
	ss_minLevel = level;
}

/// Disables output of thread/task ids with each log message
void setPlainLogging(bool enable)
{
	ss_stdoutLogger.lock().format = enable ? FileLogger.Format.plain : FileLogger.Format.thread;
}

/// Sets a log file for disk logging
void setLogFile(string filename, LogLevel min_level = LogLevel.error)
{
	auto logger = new shared(FileLogger)(filename);
	logger.lock().minLevel = min_level;
	ss_loggers ~= logger;
}

void registerLogger(shared(Logger) logger)
{
	ss_loggers ~= logger;
}

/**
	Logs a message.

	Params:
		level = The log level for the logged message
		fmt = See http://dlang.org/phobos/std_format.html#format-string

	Examples:
	---
	logInfo("Hello, World!");
	logWarn("This may not be %s.", "good");
	log!(LogLevel.info)("This is a %s.", "test");
	---
*/
void log(LogLevel level, /*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args)
nothrow {
	static assert(level != LogLevel.none);
	if (level < ss_minLevel || ss_loggers.empty) return;
	try {
		auto app = appender!string();
		formattedWrite(app, fmt, args);
		rawLog(/*mod, func,*/ file, line, level, app.data);
	} catch(Exception) assert(false);
}
/// ditto
void logVerbose4(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.verbose4/*, mod, func*/, file, line)(fmt, args); }
/// ditto
void logVerbose3(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.verbose3/*, mod, func*/, file, line)(fmt, args); }
/// ditto
void logVerbose2(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.verbose2/*, mod, func*/, file, line)(fmt, args); }
/// ditto
void logVerbose1(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.verbose1/*, mod, func*/, file, line)(fmt, args); }
/// ditto
void logTrace(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.trace/*, mod, func*/, file, line)(fmt, args); }
/// ditto
void logDebug(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.debug_/*, mod, func*/, file, line)(fmt, args); }
/// ditto
void logInfo(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.info/*, mod, func*/, file, line)(fmt, args); }
/// ditto
void logWarn(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.warn/*, mod, func*/, file, line)(fmt, args); }
/// ditto
void logError(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.error/*, mod, func*/, file, line)(fmt, args); }
/// ditto
void logCritical(/*string mod = __MODULE__, string func = __FUNCTION__,*/ string file = __FILE__, int line = __LINE__, T...)(string fmt, auto ref T args) nothrow { log!(LogLevel.critical/*, mod, func*/, file, line)(fmt, args); }


private void rawLog(/*string mod, string func,*/ string file, int line, LogLevel level, string text)
nothrow {
	static uint makeid(void* ptr) { return (cast(ulong)ptr & 0xFFFFFFFF) ^ (cast(ulong)ptr >> 32); }

	LogLine msg;
	try {
		msg.time = Clock.currTime(UTC());
		//msg.mod = mod;
		//msg.func = func;
		msg.file = file;
		msg.line = line;
		msg.level = level;
		msg.thread = Thread.getThis();
		msg.threadID = makeid(cast(void*)msg.thread);
		msg.fiber = Fiber.getThis();
		msg.fiberID = makeid(cast(void*)msg.fiber);

		foreach (ln; text.splitter("\n")) {
			msg.text = ln;
			foreach (l; ss_loggers) l.lock().log(msg);
		}
	} catch(Exception) assert(false);
}

/// Specifies the log level for a particular log message.
enum LogLevel {
	verbose4,
	verbose3,
	verbose2,
	verbose1,
	trace = verbose2,
	debug_ = verbose1,
	info,
	warn,
	error,
	critical,
	fatal,
	none,

	/// deprecated
	Trace = trace,
	/// deprecated
	Debug = debug_,
	/// deprecated
	Info = info,
	/// deprecated
	Warn = warn,
	/// deprecated
	Error = error,
	/// deprecated
	Critical = critical,
	/// deprecated
	None = none
}

struct LogLine {
	string mod;
	string func;
	string file;
	int line;
	LogLevel level;
	Thread thread;
	string threadName;
	uint threadID;
	Fiber fiber;
	uint fiberID;
	SysTime time;
	string text;
}

class Logger {
	abstract void log(ref LogLine message);
}

class FileLogger : Logger {
	enum Format {
		plain,
		thread,
		threadTime
	}

	private {
		File m_infoFile;
		File m_diagFile;
	}

	Format format = Format.thread;
	LogLevel minLevel = LogLevel.min;

	this(File info_file, File diag_file)
	{
		m_infoFile = info_file;
		m_diagFile = diag_file;
	}

	this(string filename)
	{
		m_infoFile = File(filename, "ab");
		m_diagFile = m_infoFile;
	}

	override void log(ref LogLine msg)
	{
		if (msg.level < this.minLevel) return;

		string pref;
		File file;
		final switch (msg.level) {
			case LogLevel.verbose4: pref = "v4"; file = m_diagFile; break;
			case LogLevel.verbose3: pref = "v3"; file = m_diagFile; break;
			case LogLevel.trace: pref = "trc"; file = m_diagFile; break;
			case LogLevel.debug_: pref = "dbg"; file = m_diagFile; break;
			case LogLevel.info: pref = "INF"; file = m_infoFile; break;
			case LogLevel.warn: pref = "WRN"; file = m_diagFile; break;
			case LogLevel.error: pref = "ERR"; file = m_diagFile; break;
			case LogLevel.critical: pref = "CRITICAL"; file = m_diagFile; break;
			case LogLevel.fatal: pref = "FATAL"; file = m_diagFile; break;
			case LogLevel.none: assert(false);
		}

		final switch (this.format) {
			case Format.plain: file.write(msg.text); break;
			case Format.thread: file.writefln("[%08X:%08X %s] %s", msg.threadID, msg.fiberID, pref, msg.text); break;
			case Format.threadTime:
				auto tm = msg.time;
				file.writefln("[%08X:%08X %d.%02d.%02d %02d:%02d:%02d.%03d %s] %s",
					msg.threadID, msg.fiberID,
					tm.year, tm.month, tm.day, tm.hour, tm.minute, tm.second, tm.fracSec.msecs,
					pref, msg.text);
				break;
		}
		file.flush();
	}
}


class HtmlLogger : Logger {
	private {
		File m_logFile;
	}

	this(string filename = "log.html")
	{
		m_logFile = File(filename, "wt");
		writeHeader();
	}

	~this()
	{
		//version(FinalizerDebug) writeln("HtmlLogWritet.~this");
		writeFooter();
		m_logFile.close();
		//version(FinalizerDebug) writeln("HtmlLogWritet.~this out");
	}

	override void log(ref LogLine msg)
	{
		if( !m_logFile.isOpen ) return;

		final switch (msg.level) {
			case LogLevel.none: assert(false);
			case LogLevel.verbose4: m_logFile.write(`<div class="verbose4">`); break;
			case LogLevel.verbose3: m_logFile.write(`<div class="verbose3">`); break;
			case LogLevel.verbose2: m_logFile.write(`<div class="verbose2">`); break;
			case LogLevel.verbose1: m_logFile.write(`<div class="verbose1">`); break;
			case LogLevel.info: m_logFile.write(`<div class="info">`); break;
			case LogLevel.warn: m_logFile.write(`<div class="warn">`); break;
			case LogLevel.error: m_logFile.write(`<div class="error">`); break;
			case LogLevel.critical: m_logFile.write(`<div class="critical">`); break;
			case LogLevel.fatal: m_logFile.write(`<div class="fatal">`); break;
		}
		m_logFile.writef(`<div class="timeStamp">%s</div>`, msg.time.toISOExtString());
		m_logFile.writef(`<div class="threadName">%s</div>`, msg.thread.name);
		m_logFile.writef(`<div class="message">%s</div>`, msg.text);
		m_logFile.writeln(`</div>`);
		m_logFile.flush();
	}

	private void writeHeader(){
		if( !m_logFile.isOpen ) return;

		m_logFile.writeln(
`<html>
<head>
	<title>HTML Log</title>
	<style content="text/css">
		.verbose4 { position: relative; color: #E0E0E0; font-size: 9pt; }
		.verbose3 { position: relative; color: #E0E0E0; font-size: 9pt; }
		.verbose2 { position: relative; color: #E0E0E0; font-size: 9pt; }
		.verbose1 { position: relative; color: #808080; }
		.info { position: relative; color: black; }
		.warn { position: relative; color: #E08000; }
		.error { position: relative; color: red; }
		.critical { position: relative; color: red; background-color: black; }
		.fatal { position: relative; color: red; background-color: black; }

		.log { margin-left: 10pt; }
		.code {
			font-family: "Courier New";
			background-color: #F0F0F0;
			border: 1px solid gray;
			margin-bottom: 10pt;
			margin-left: 30pt;
			margin-right: 10pt;
			padding-left: 0pt;
		}

		div.timeStamp {
			position: absolute;
			width: 150pt;
		}
		div.threadName {
			position: absolute;
			top: 0pt;
			left: 150pt;
			width: 100pt;
		}
		div.message {
			position: relative;
			top: 0pt;
			left: 250pt;
		}
		body {
			font-family: Tahoma, Arial, sans-serif;
			font-size: 10pt;
		}
	</style>
	<script language="JavaScript">
		function enableStyle(i){
			var style = document.styleSheets[0].cssRules[i].style;
			style.display = "block";
		}

		function disableStyle(i){
			var style = document.styleSheets[0].cssRules[i].style;
			style.display = "none";
		}

		function updateLevels(){
			var sel = document.getElementById("Level");
			var level = sel.value;
			for( i = 0; i < level; i++ ) disableStyle(i);
			for( i = level; i < 5; i++ ) enableStyle(i);
		}
	</script>
</head>
<body style="padding: 0px; margin: 0px;" onLoad="updateLevels(); updateCode();">
	<div style="position: fixed; z-index: 100; padding: 4pt; width:100%; background-color: lightgray; border-bottom: 1px solid black;">
		<form style="margin: 0px;">
			Minimum Log Level:
			<select id="Level" onChange="updateLevels()">
				<option value="0">Verbose 4</option>
				<option value="1">Verbose 3</option>
				<option value="2">Verbose 2</option>
				<option value="3">Verbose 1</option>
				<option value="4">Info</option>
				<option value="5">Warn</option>
				<option value="6">Error</option>
				<option value="7">Critical</option>
				<option value="8">Fatal</option>
			</select>
		</form>
	</div>
	<div style="height: 30pt;"></div>
	<div class="log">`);
		m_logFile.flush();
	}

	private void writeFooter(){
		if( !m_logFile.isOpen ) return;

		m_logFile.writeln(
`	</div>
</body>
</html>`);
		m_logFile.flush();
	}
}

private {
	shared LogLevel ss_minLevel = LogLevel.info;
	shared Logger[] ss_loggers;
	shared(FileLogger) ss_stdoutLogger;
	shared(FileLogger) ss_fileLogger;
}

package void initializeLogModule()
{
	ss_stdoutLogger = new shared(FileLogger)(stdout, stderr);
	ss_loggers ~= ss_stdoutLogger;
}