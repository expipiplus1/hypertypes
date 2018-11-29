{-# LANGUAGE LambdaCase #-}

import TermLang
import TypeLang

import AST
import AST.Unify
import AST.Unify.IntBindingState
import qualified Control.Lens as Lens
import Control.Lens.Operators
import Control.Monad.RWS
import Data.Functor.Identity
import Data.Map
import Data.Maybe

type LamBindings v = Map String (Node (UTerm v) Typ)

type InferM = RWST (LamBindings Int) () (Infer IntBindingState) Maybe

runInfer :: InferM a -> Maybe a
runInfer act = runRWST act mempty emptyInferState <&> (^. Lens._1)

infer :: Term String Identity -> InferM (Node (UTerm Int) Typ)
infer ELit{} = UTerm TInt & pure
infer (EVar var) = Lens.view (Lens.at var) <&> fromMaybe (error "name error")
infer (ELam var (Identity body)) =
    do
        varType <- newVar binding
        local (Lens.at var ?~ varType) (infer body) <&> TFun varType <&> UTerm
infer (EApp (Identity func) (Identity arg)) =
    do
        argType <- infer arg
        infer func
            >>=
            \case
            UTerm (TFun funcArg funcRes) ->
                -- Func already inferred to be function,
                -- skip creating new variable for result for faster inference.
                funcRes <$ unify funcArg argType
            x ->
                do
                    funcRes <- newVar binding
                    funcRes <$ unify x (UTerm (TFun argType funcRes))

expr :: Node Identity (Term String)
expr =
    -- \x -> x 5
    ELit 5 & Identity
    & EApp (EVar "x" & Identity) & Identity
    & ELam "x" & Identity

occurs :: Node Identity (Term String)
occurs =
    -- \x -> x x
    EApp x x & Identity
    & ELam "x" & Identity
    where
        x = EVar "x" & Identity

inferExpr :: Node Identity (Term String) -> Maybe (Node (UTerm Int) Typ)
inferExpr x = infer (x ^. Lens._Wrapped) >>= applyBindings & runInfer

main :: IO ()
main =
    do
        putStrLn ""
        print (inferExpr expr)
        print (inferExpr occurs)
