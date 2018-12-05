{-# LANGUAGE StandaloneDeriving, UndecidableInstances, TemplateHaskell, TypeFamilies #-}

module TermLang where

import AST
import AST.Recursive
import AST.Scope
import AST.TH

data Term v f
    = ELam (Scope Term v f)
    | EVar v
    | EApp (Node f (Term v)) (Node f (Term v))
    | ELit Int

makeChildren [''Term]
instance ChildrenRecursive (Term v)
