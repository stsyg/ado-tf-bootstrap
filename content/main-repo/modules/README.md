# Modules

Local modules, one folder each, called from `main.tf` with `source = "./modules/<name>"`.
Give each a `README.md`, `variables.tf`, `outputs.tf` and, where it has logic, a `tests/` folder of
`terraform test` files; the CI pipeline's format check covers this folder too.
