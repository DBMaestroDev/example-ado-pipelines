A Developer modifies the shared database.
Source Control captures the change.
Developer commits the captured changes specifying a commit message and a TaskId value.
The pushed commit triggers the ADO pipeline to build a DBmaestro package.
    The package is named after the TaskId+<shorthash>. It is also assined a Tag equals to TaskId.
After approval, the package is then deployed to the integration environment (Release Source)
Then it can then be promoted to higher environments.
If a fix is required for this TaskId:
    The pipeline must be cancelled.
    The Developer will modify the shared database and make a new commit.
    A new package will be created name TaskId+<shorthash>.
    It will have the same Tag as the previous package.
    The fix will be applied to Release Source.
    Since both packages share the same tag, higher environments will recieve both the original package and the fix in the required order.