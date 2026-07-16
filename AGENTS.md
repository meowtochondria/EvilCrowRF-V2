1. **Read first, act second** — always read the relevant code before making changes.
2. **Verify with diagnostics tool** — after every batch of changes, call the `diagnostics` tool (no path argument) to check for errors project-wide. 
3. **Effective and maintainable code** - Use software design patterns where necessary to make effective and maintainable code.
4. **Small, focused changes** — one file/task at a time. Don't batch unrelated changes.
5. **Match existing patterns** — don't introduce new architectural patterns unless the change explicitly calls for it.
6. **Don't fix unrelated bugs** — if you find a pre-existing issue, mention it but don't fix it unless asked.
7. **Don't commit** — the user commits manually. Just make the code changes.
8. **Maintain work log** - If executing on a plan via markdown file, update the progress in the file.
9. **No phase number in comments** - If implementing a phased plan, do not reference anything related to phase in code or comments.
10. When stubbing code, call it out loudly in summary.
11. When building or modifying functionality, ensure that new code is invoked by existing code path, or add new code paths. Call it out in summary.
