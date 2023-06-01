{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module LangD where

import Hyper

newtype A i k = A (B i k)
newtype B i k = B (i (k :# A i))

makeHTraversableApplyAndBases ''B
makeHTraversableApplyAndBases ''A

newtype C (k :: AHyperType) = C (C k)

-- The following doesn't work:
-- makeHNodes ''C

newtype D a (h :: AHyperType) = D (a h)
newtype E a (h :: AHyperType) = E (D a h)

makeHTraversableAndBases ''D
makeHTraversableAndBases ''E
