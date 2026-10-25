// The system SQLite header. The library to link is chosen per platform in
// Package.swift (`sqlite3` on Linux, `winsqlite3` on Windows).
#if defined(_WIN32)
#include <winsqlite/winsqlite3.h>
#else
#include <sqlite3.h>
#endif
