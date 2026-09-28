#!/usr/bin/env bash
# 编 kc_store 的独立验证 exe（不需要 Godot、不需要宠物在跑）
#
#   ./build_store.sh && ./test_store.exe
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQLITE_FLAGS="-DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 -DSQLITE_DEFAULT_MEMSTATUS=0"

cd "$ROOT/native"

echo "[1/2] 编 SQLite amalgamation（9.5MB 的 C 文件，约需 20-60 秒）"
gcc -c -O2 $SQLITE_FLAGS -I"$ROOT/thirdparty/sqlite" \
	"$ROOT/thirdparty/sqlite/sqlite3.c" -o sqlite3.o

echo "[2/2] 编 kc_store + 自检程序"
g++ -std=c++17 -O2 -Wall -Wextra -static -static-libgcc -static-libstdc++ \
	-I"$ROOT/thirdparty/sqlite" -I"$ROOT/native" \
	kc_store.cpp test_store.cpp sqlite3.o -o test_store.exe

rm -f sqlite3.o
echo "完成：native/test_store.exe"
