# nixpkgs at the revision devenv.lock pins for the root `nixpkgs` input (the
# one the shell uses). Used by check-tools.nix and by the check workflow's
# devenv install, so every consumer agrees on versions.
let
  lock = builtins.fromJSON (builtins.readFile ../devenv.lock);
  ref = lock.nodes.root.inputs.nixpkgs or (throw "devenv.lock: the root has no nixpkgs input");
  node =
    if builtins.isString ref then
      lock.nodes.${ref}
    else
      throw "devenv.lock: the root nixpkgs input is a follows list (${builtins.toJSON ref}), not a node name; scripts/pinned-nixpkgs.nix must resolve it";
in
import (builtins.fetchTree node.locked) { }
