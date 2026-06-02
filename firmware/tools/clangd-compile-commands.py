Import("env")

# include toolchain paths
# env.Replace(COMPILATIONDB_INCLUDE_TOOLCHAIN=True)

# override compilation DB path
compilation_db_path = env.GetProjectOption("COMPILATIONDB_PATH")
env.Replace(COMPILATIONDB_PATH=compilation_db_path)
