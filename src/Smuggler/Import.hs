module Smuggler.Import where

import           Avail
import           BasicTypes
import           Control.Monad                  ( unless )
import           Data.List                      ( foldl' )
import           Data.Maybe                     ( isNothing )
import           DynFlags                       ( DynFlags )
import           GHC                            ( AnnKeywordId(..)
                                                , GhcPs
                                                , HsModule
                                                , hsmodImports
                                                , ieName
                                                )
import           HsImpExp                       ( IE
                                                  ( IEThingAbs
                                                  , IEThingAll
                                                  , IEThingWith
                                                  , IEVar
                                                  )
                                                , IEWrappedName(IEName)
                                                , ImportDecl
                                                  ( ideclHiding
                                                  , ideclName
                                                  )
                                                , LIE
                                                , LIEWrappedName
                                                , LImportDecl
                                                , ideclImplicit
                                                , ieLWrappedName
                                                , pprImpExp
                                                )
import           HsSyn                          ( GhcRn )
import           Language.Haskell.GHC.ExactPrint.Print
                                                ( exactPrint )
import           Language.Haskell.GHC.ExactPrint.Transform
                                                ( TransformT
                                                , addSimpleAnnT
                                                , logDataWithAnnsTr
                                                , logTr
                                                , removeTrailingCommaT
                                                , runTransform
                                                , setEntryDPT
                                                , uniqueSrcSpanT
                                                )
import           Language.Haskell.GHC.ExactPrint.Types
                                                ( Anns
                                                , DeltaPos(DP)
                                                , KeywordId(G)
                                                , noExt
                                                )
import           Language.Haskell.GHC.ExactPrint.Utils
                                                ( debug
                                                , ss2posEnd
                                                )
import           LoadIface
import           Name                           ( Name
                                                , nameSrcSpan
                                                )
import           Outputable
import           PrelNames                      ( pRELUDE_NAME )
import           RdrName                        ( GlobalRdrElt(..) )
import           RnNames                        ( ImportDeclUsage
                                                , findImportUsage
                                                , getMinimalImports
                                                )
import           Smuggler.Anns                  ( removeAnnAtLoc
                                                , removeLocatedKeywordT
                                                , removeTrailingCommas
                                                )
import           Smuggler.Export                ( mkLIEVarFromNameT
                                                , addCommaT
                                                , addParensT
                                                ) -- TODO:: take this out of Exports
import           Smuggler.Options               ( ImportAction(..) )
import           SrcLoc                         ( GenLocated(L)
                                                , Located
                                                , SrcSpan(..)
                                                , srcSpanEndCol
                                                , srcSpanEndLine
                                                , srcSpanStartCol
                                                , srcSpanStartLine
                                                , unLoc
                                                )
import           TcRnTypes

minimiseImports
  :: DynFlags
  -> ImportAction
  -> [LImportDecl GhcRn]
  -> [GlobalRdrElt]
  -> (Anns, Located (HsModule GhcPs))
  -> (Anns, Located (HsModule GhcPs))
minimiseImports dflags action user_imports uses p@(anns, ast@(L astLoc hsMod))
  = case action of
    NoImportProcessing -> p
    _                  -> (anns', L astLoc hsMod')
--      trace ("usage\n" ++ showSDoc dflags (ppr usage)) (anns', L astLoc hsMod')


 where

  imports :: [LImportDecl GhcPs]
  imports = hsmodImports hsMod

  -- ImportDeclUsage = (LImportDecl GhcRn, used: [AvailInfo], unused: [Name])
  usage :: [ImportDeclUsage]
  usage             = findImportUsage user_imports uses

  (anns', imports') = findUsedImports anns imports usage
  hsMod'            = hsMod { hsmodImports = imports' }

  findUsedImports
    :: Anns
    -> [LImportDecl GhcPs]
    -> [ImportDeclUsage]
    -> (Anns, [LImportDecl GhcPs])
  findUsedImports anns [] [] = (anns, [])
  findUsedImports anns (p : ps) (r : rs) =
    (anns'', usedImports ++ usedImports')
   where
    (anns' , usedImports ) = usedImport dflags action anns p r
    (anns'', usedImports') = findUsedImports anns' ps rs

-- TODO: rewrite this as a transform, like Export?

-- TODO: reuse more logic from GHC. Is it possible?
usedImport
  :: DynFlags
  -> ImportAction
  -> Anns
  -> LImportDecl GhcPs
  -> ImportDeclUsage
  -> (Anns, [LImportDecl GhcPs])
usedImport _ _ anns impPs (L (UnhelpfulSpan _) _, _, _) = (anns, [])
usedImport dynflags action anns impPs@(L (RealSrcSpan locPs) declPs) (impRn@(L (RealSrcSpan locRn) declRn), used, unused)
  | -- Do not remove `import M ()`
    Just (False, L _ []) <- ideclHiding declRn
  = (anns, [impPs])
  | -- Note [Do not warn about Prelude hiding]
    -- TODO: add ability to support custom prelude
    Just (True, L _ hides) <- ideclHiding declRn
  , not (null hides)
  , ideclImplicit declRn -- pRELUDE_NAME == unLoc (ideclName decl)
  = (anns, [impPs])
  | -- Nothing used
    null used
  = case action of
    PreserveInstanceImports -> case ideclHiding declRn of
      Nothing -> -- add (), to import instances only
        let (ast', (anns', _n), _s) = runTransform anns $ do
              locHiding <- uniqueSrcSpanT
              let lies = L locHiding [] :: Located [LIE GhcPs]
              addParensT lies
              let declPs' = declPs { ideclHiding = Just (False, lies) }
              let impPs'  = L (RealSrcSpan locPs) declPs'
              return [impPs']
        in  (anns', ast')
      Just (False, L lieLoc _) -> -- just leave the ()
        let (ast', (anns', _n), _s) = runTransform anns $ do
              lieLoc' <- uniqueSrcSpanT
              let noLIEs = L lieLoc' [] :: Located [LIE GhcPs]
              addParensT noLIEs
              let declPs' = declPs { ideclHiding = Just (False, noLIEs) }
              let impPs'  = L (RealSrcSpan locPs) declPs'
              return [impPs']
        in  (anns', ast')
      -- TODO:: unised hidings. Leave as a noop for now
      Just (True, _) -> (anns, [impPs])
    MinimiseImports    -> (anns, [])  -- Drop the import
    NoImportProcessing -> (anns, [impPs])
  | not (null used)
  = case action of
    NoImportProcessing -> (anns, [impPs])
    _                  -> case ideclHiding declRn of
      Nothing ->
        let
          (ast', (anns', _n), _s) = runTransform anns $ do
            let names = map gre_name used
            importList <- mapM mkLIEVarFromNameT names
            unless (null importList) $ mapM_ addCommaT (init importList)
            let lImportList = L (RealSrcSpan locPs) importList -- locPS or unique?
                declPs'     = declPs { ideclHiding = Just (False, lImportList) }
            addParensT lImportList
            let impPs' = L (RealSrcSpan locPs) declPs'
            return [impPs']
        in  (anns', ast')

      Just (False, L _ liesRn) ->
        let
          Just (False, L locLIE liesPs) = ideclHiding declPs
          (usedImportsPs, anns')        = usedLImportDeclsPs anns liesPs liesRn
          declPs' =
            declPs { ideclHiding = Just (False, L locLIE usedImportsPs) }
          impPs' = L (RealSrcSpan locPs) declPs'
        in
          (anns', [impPs'])
      -- TODO:: unused hidings. Leave as a noop for now
      Just (True, _) -> (anns, [impPs])
 where

  -- TODO:: turn into a fold, or use monoid to make less ugly

  usedLImportDeclsPs
    :: Anns -> [LIE GhcPs] -> [LIE GhcRn] -> ([LIE GhcPs], Anns)
  usedLImportDeclsPs anns liesPs liesRn = removeTrailingComma
    (concat liesPs', anns')
   where
    (liesPs', anns') = usedLImportDeclsPss anns liesPs liesRn

    removeTrailingComma :: ([LIE GhcPs], Anns) -> ([LIE GhcPs], Anns)
    removeTrailingComma ([]  , anns) = ([], anns)
    removeTrailingComma (lies, anns) = (lies', anns')
     where
      (lies', (anns', _), _) = runTransform anns $ do
        removeTrailingCommaT (last lies)
        setEntryDPT (head lies) (DP (0, 0))
        return lies

    usedLImportDeclsPss
      :: Anns -> [LIE GhcPs] -> [LIE GhcRn] -> ([[LIE GhcPs]], Anns)
    usedLImportDeclsPss anns [] [] = ([[]], anns)
    usedLImportDeclsPss anns (liePs : liesPs) (lieRn : liesRn) =
      let (liesPs', anns' ) = usedLImportDeclsPss anns liesPs liesRn
          (liePs' , anns'') = usedLImportDeclPs anns' liePs lieRn
      in  (liePs' : liesPs', anns'')


    usedLImportDeclPs :: Anns -> LIE GhcPs -> LIE GhcRn -> ([LIE GhcPs], Anns)
    usedLImportDeclPs anns liePs lieRn =
      if ieName (unLoc lieRn) `elem` map gre_name used -- TODO: factor this out
        then
--      let (ast', (anns', _), s) = runTransform anns $ do
--            -- Superfluous
--            removeTrailingCommaT liePs
--            removeLocatedKeywordT (G GHC.AnnVal) liePs
--            return []
--      in   ([], anns')
             ([liePs], anns)
        else ([], anns)

