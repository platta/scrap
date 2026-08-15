# components/backup/

Not yet implemented.

Will provide: the label convention that makes a PVC discoverable by `platform/backup/`'s
label-driven engine, plus the optional pattern for declaring a consistency method (a logical dump
command for a database, a quiesce command, or nothing for plain file copy). See
`platform/backup/README.md` for the full contract this component opts an application into.
