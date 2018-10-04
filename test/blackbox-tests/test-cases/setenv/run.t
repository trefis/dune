  $ dune build --root . toto
  Info: creating file dune-project with this contents: (lang dune 1.4)
  File "dune", line 3, characters 19-25:
  3 |  (action (setenv %{prout} pouet (echo "done."))))
                         ^^^^^^
  Error: Unknown variable "prout"
  [1]
