module Backend where

import Debug.Trace
import Prelude.Unsafe (unsafeIndex)

import qualified Graphics.WebGLRaw as GL
import Control.Monad.Eff.Exception
import Control.Monad.Eff.WebGL
import Control.Monad.Eff.Ref
import Control.Monad.Eff
import Control.Monad
import Control.Bind
import Data.Foldable
import Data.Traversable
import qualified Data.StrMap as StrMap
import qualified Data.Map as Map
import Data.Tuple
import Data.Maybe
import Data.Maybe.Unsafe
import Data.Array

import Type
import IR
import Util
import Input

setupRasterContext :: RasterContext -> GFX Unit
setupRasterContext = cvt
  where
    cff :: FrontFace -> GL.GLenum
    cff CCW = GL._CCW
    cff CW  = GL._CW

    -- not presented in WebGL
    {-
    setProvokingVertex :: ProvokingVertex -> IO ()
    setProvokingVertex pv = glProvokingVertex $ case pv of
        FirstVertex -> gl_FIRST_VERTEX_CONVENTION
        LastVertex  -> gl_LAST_VERTEX_CONVENTION
    -}

    setPointSize :: PointSize -> GFX Unit
    setPointSize ps = case ps of
        ProgramPointSize    -> return unit
        PointSize s         -> trace "PointSize is not supported!"

    cvt :: RasterContext -> GFX Unit
    cvt (PointCtx ps fts sc) = do
        setPointSize ps
        {-
        glPointParameterf gl_POINT_FADE_THRESHOLD_SIZE (realToFrac fts)
        glPointParameterf gl_POINT_SPRITE_COORD_ORIGIN $ realToFrac $ case sc of
            LowerLeft   -> gl_LOWER_LEFT
            UpperLeft   -> gl_UPPER_LEFT
        -}

    cvt (LineCtx lw pv) = do
        GL.lineWidth_ lw
        --setProvokingVertex pv

    cvt (TriangleCtx cm pm po pv) = do
        -- cull mode
        case cm of
            CullNone    -> GL.disable_ GL._CULL_FACE
            CullFront f -> do
                GL.enable_    GL._CULL_FACE
                GL.cullFace_  GL._FRONT
                GL.frontFace_ $ cff f
            CullBack f -> do
                GL.enable_    GL._CULL_FACE
                GL.cullFace_  GL._BACK
                GL.frontFace_ $ cff f

        -- polygon mode
        -- not presented
        {-
        case pm of
            PolygonPoint ps -> do
                setPointSize ps
                glPolygonMode gl_FRONT_AND_BACK gl_POINT
            PolygonLine lw  -> do
                GL.lineWidth_ lw
                glPolygonMode gl_FRONT_AND_BACK gl_LINE
            PolygonFill  -> glPolygonMode gl_FRONT_AND_BACK gl_FILL
        -}
        -- polygon offset
        -- not presented: glDisable gl_POLYGON_OFFSET_POINT
        -- not presented: glDisable gl_POLYGON_OFFSET_LINE
        GL.disable_ GL._POLYGON_OFFSET_FILL
        case po of
            NoOffset -> return unit
            Offset f u -> do
                GL.polygonOffset_ f u
                GL.enable_ GL._POLYGON_OFFSET_FILL

        -- provoking vertex
        -- not presented: setProvokingVertex pv

setupAccumulationContext :: AccumulationContext -> GFX Unit
setupAccumulationContext (AccumulationContext {accViewportName = n, accOperations = ops}) = cvt ops
  where
    cvt :: [FragmentOperation] -> GFX Unit
    cvt (StencilOp a b c : DepthOp f m : xs) = do
        -- TODO
        cvtC 0 xs
    cvt (StencilOp a b c : xs) = do
        -- TODO
        cvtC 0 xs
    cvt (DepthOp df dm : xs) = do
        -- TODO
        GL.disable_ GL._STENCIL_TEST
        let glDF = comparisonFunctionToGLType df
        case glDF == comparisonFunctionToGLType Always && dm == false of
            true    -> GL.disable_ GL._DEPTH_TEST
            false   -> do
                GL.enable_ GL._DEPTH_TEST
                GL.depthFunc_ glDF
                GL.depthMask_ dm
        cvtC 0 xs
    cvt xs = do 
        GL.disable_ GL._DEPTH_TEST
        GL.disable_ GL._STENCIL_TEST
        cvtC 0 xs

    cvtC :: Int -> [FragmentOperation] -> GFX Unit
    cvtC i (ColorOp b m : xs) = do
        -- TODO
        case b of
            NoBlending -> do
                -- FIXME: requires GL 3.1
                --glDisablei gl_BLEND $ fromIntegral gl_DRAW_BUFFER0 + fromIntegral i
                GL.disable_ GL._BLEND -- workaround
                -- not presented: GL.disable_ GL._COLOR_LOGIC_OP
            BlendLogicOp op -> do
                GL.disable_ GL._BLEND
                -- not presented: GL.enable_  GL._COLOR_LOGIC_OP
                -- not presented: GL.logicOp_ $ logicOperationToGLType op
                trace "not presented: BlendLogicOp"
            Blend eq fac (V4 r g b a) -> do
                -- not presented: glDisable gl_COLOR_LOGIC_OP
                -- FIXME: requires GL 3.1
                --glEnablei gl_BLEND $ fromIntegral gl_DRAW_BUFFER0 + fromIntegral i
                GL.enable_ GL._BLEND -- workaround
                GL.blendEquationSeparate_ (blendEquationToGLType eq.colorEq) (blendEquationToGLType eq.alphaEq)
                GL.blendColor_ r g b a
                BlendingFactorPair colorF <- pure fac.colorF
                BlendingFactorPair alphaF <- pure fac.alphaF
                GL.blendFuncSeparate_ (blendingFactorToGLType colorF.src) (blendingFactorToGLType colorF.dst)
                                      (blendingFactorToGLType alphaF.src) (blendingFactorToGLType alphaF.dst)
        case m of
          VBool r           -> GL.colorMask_ r true true true
          VV2B (V2 r g)     -> GL.colorMask_ r g true true
          VV3B (V3 r g b)   -> GL.colorMask_ r g b true
          VV4B (V4 r g b a) -> GL.colorMask_ r g b a
          _                 -> GL.colorMask_ true true true true
        cvtC (i + 1) xs
    cvtC _ [] = return unit


clearRenderTarget :: [ClearImage] -> GFX Unit
clearRenderTarget values = do
    let setClearValue {mask:m,index:i} (ClearImage val) = case val of
            {semantic = Depth, value = VFloat v} -> do
                GL.depthMask_ true
                GL.clearDepth_ v
                return {mask:m .|. GL._DEPTH_BUFFER_BIT, index:i}
            {semantic = Stencil, value = VWord v} -> do
                GL.clearStencil_ v
                return {mask:m .|. GL._STENCIL_BUFFER_BIT, index:i}
            {semantic = Color, value = c} -> do
                case c of
                  VFloat r            -> GL.clearColor_ r 0 0 1
                  VV2F (V2 r g)       -> GL.clearColor_ r g 0 1
                  VV3F (V3 r g b)     -> GL.clearColor_ r g b 1
                  VV4F (V4 r g b a)   -> GL.clearColor_ r g b a
                  _                   -> GL.clearColor_ 0 0 0 1
                GL.colorMask_ true true true true
                return {mask:m .|. GL._COLOR_BUFFER_BIT, index:i+1}
            _ -> throwException $ error "internal error (clearRenderTarget)"
    m <- foldM setClearValue {mask:0,index:0} values
    GL.clear_ m.mask

compileProgram :: StrMap.StrMap InputType -> Program -> GFX GLProgram
compileProgram uniTrie (Program p) = do
    po <- GL.createProgram_
    let createAndAttach src t = do
          o <- GL.createShader_ t
          GL.shaderSource_ o src
          GL.compileShader_ o
          log <- GL.getShaderInfoLog_ o
          trace log
          status <- GL.getShaderParameter_ o GL._COMPILE_STATUS
          when (status /= true) $ throwException $ error "compileShader failed!"
          GL.attachShader_ po o
          --putStr "    + compile shader source: " >> printGLStatus
          return o

    objV <- createAndAttach p.vertexShader GL._VERTEX_SHADER
    objF <- createAndAttach p.fragmentShader GL._FRAGMENT_SHADER

    GL.linkProgram_ po
    prgLog <- GL.getProgramInfoLog_ po
    trace prgLog

    -- check link status
    status <- GL.getProgramParameter_ po GL._LINK_STATUS
    when (status /= true) $ throwException $ error "link program failed!"

    uniformLocation <- StrMap.fromList <$> for (StrMap.toList p.programUniforms) (\(Tuple uniName uniType) -> do
      loc <- GL.getUniformLocation_ po uniName
      return $ Tuple uniName loc)

    samplerLocation <- StrMap.fromList <$> for (StrMap.toList p.programInTextures) (\(Tuple uniName uniType) -> do
      loc <- GL.getUniformLocation_ po uniName
      return $ Tuple uniName loc)

    streamLocation <- StrMap.fromList <$> for (StrMap.toList p.programStreams) (\(Tuple streamName (Parameter s)) -> do
      loc <- GL.getAttribLocation_ po streamName
      trace $ "attrib location " ++ streamName ++" " ++ show loc
      return $ Tuple streamName {location: loc, slotAttribute: s.name})

    return {program: po, shaders: [objV,objF], inputUniforms: uniformLocation, inputSamplers:samplerLocation, inputStreams: streamLocation}

foreign import nullWebGLFramebuffer "var nullWebGLFramebuffer = null" :: GL.WebGLFramebuffer

compileRenderTarget :: [TextureDescriptor] -> [GLTexture] -> RenderTarget -> GFX GLRenderTarget
compileRenderTarget texs glTexs (RenderTarget rt) = do
  let targets = rt.renderTargets
      isFB (Framebuffer _)    = true
      isFB _                  = false
      images = map (\(TargetItem a) -> fromJust a.ref) $ filter (\(TargetItem a) -> isJust a.ref) targets
      act1 = case all isFB images of
          true -> do
              let isColor Color = true
                  isColor _ = false
                  cvt (TargetItem a) = case a.ref of
                      Nothing                     -> return GL._NONE
                      Just (Framebuffer Color)    -> return GL._BACK
                      _                           -> throwException $ error "internal error (compileRenderTarget)!"
              bufs <- traverse cvt $ filter (\(TargetItem a) -> isColor a.semantic) targets
              return $
                  { framebufferObject: nullWebGLFramebuffer
                  , framebufferDrawbuffers: Just bufs
                  }
          false -> do
              when (any isFB images) $ throwException $ error "internal error (compileRenderTarget)!"
              fbo <- GL.createFramebuffer_
              GL.bindFramebuffer_ GL._FRAMEBUFFER fbo
              let attach attachment (TextureImage texIdx level Nothing) = do
                      let glTex = glTexs `unsafeIndex` texIdx
                          tex = texs `unsafeIndex` texIdx
                          txLevel = level
                          txTarget = glTex.textureTarget
                          txObj = glTex.textureObject
                          attach2D    = GL.framebufferTexture2D_ GL._FRAMEBUFFER attachment txTarget txObj txLevel
                          act0 = case tex of
                            TextureDescriptor t -> case t.textureType of
                              Texture2D     _ 1 -> attach2D
                              _ -> throwException $ error "invalid texture format!"
                      act0
                  attach _ _ = throwException $ error "invalid texture format!"
                  go a (TargetItem {semantic:Stencil, ref:Just img}) = do
                      throwException $ error "Stencil support is not implemented yet!"
                      return a
                  go a (TargetItem {semantic: Depth,ref: Just img}) = do
                      attach GL._DEPTH_ATTACHMENT img
                      return a
                  go (Tuple bufs colorIdx) (TargetItem {semantic: Color,ref: Just img}) = do
                      let attachment = GL._COLOR_ATTACHMENT0
                      attach attachment img
                      return (Tuple (attachment : bufs) (colorIdx + 1))
                  go (Tuple bufs colorIdx) (TargetItem {semantic: Color,ref: Nothing}) = return (Tuple (GL._NONE : bufs) (colorIdx + 1))
                  go a _ = return a
              (Tuple bufs _) <- foldM go (Tuple [] 0) targets
              return $
                  { framebufferObject: fbo
                  , framebufferDrawbuffers: Nothing
                  }
  act1

allocPipeline :: Pipeline -> GFX WebGLPipeline
allocPipeline (Pipeline p) = do
  texs <- traverse compileTexture p.textures
  trgs <- traverse (compileRenderTarget p.textures texs) p.targets
  prgs <- traverse (compileProgram StrMap.empty) p.programs
  input <- newRef Nothing
  curProg <- newRef Nothing
  return
    { targets: trgs
    , textures: texs
    , programs: prgs
    , commands: p.commands
    , input: input
    , slotPrograms: map (\(Slot a) -> a.slotPrograms) p.slots
    , slotNames: map (\(Slot a) -> a.slotName) p.slots
    , curProgram: curProg
    }

renderPipeline :: WebGLPipeline -> GFX Unit
renderPipeline p = do
  writeRef p.curProgram Nothing
  for_ p.commands $ \cmd -> case cmd of
      SetRenderTarget i -> do
        let rt = p.targets `unsafeIndex` i
        ic' <- readRef p.input
        case ic' of
            Nothing -> return unit
            Just (InputConnection ic) -> do
                        V2 w h <- readRef ic.input.screenSize
                        GL.viewport_ 0 0 w h
        -- TODO: set FBO target viewport
        GL.bindFramebuffer_ GL._FRAMEBUFFER rt.framebufferObject
        {-
        case bufs of
            Nothing -> return unit
            Just bl -> withArray bl $ glDrawBuffers (fromIntegral $ length bl)
        -}
      SetSamplerUniform n tu -> do
        readRef p.curProgram >>= \cp -> case cp of
          Nothing -> throwException $ error "invalid pipeline, no active program"
          Just progIdx -> case StrMap.lookup n (p.programs `unsafeIndex` progIdx).inputSamplers of
            Nothing -> throwException $ error "internal error (SetSamplerUniform)!"
            Just i  -> GL.uniform1i_ i tu

      SetTexture tu i -> do
        GL.activeTexture_ (GL._TEXTURE0 + tu)
        let tx = p.textures `unsafeIndex` i
        GL.bindTexture_ tx.textureTarget tx.textureObject
      SetRasterContext rCtx -> do
        --trace "SetRasterContext"
        setupRasterContext rCtx
      SetAccumulationContext aCtx -> do
        --trace "SetAccumulationContext"
        setupAccumulationContext aCtx
      ClearRenderTarget t -> do
        --trace "ClearRenderTarget"
        clearRenderTarget t
      SetProgram i -> do
        --trace $ "SetProgram " ++ show i
        writeRef p.curProgram (Just i)
        GL.useProgram_ $ (p.programs `unsafeIndex` i).program
      RenderSlot slotIdx -> do
        --trace $ "RenderSlot " ++ show slotIdx
        readRef p.curProgram >>= \cp -> case cp of
          Nothing -> throwException $ error "invalid pipeline, no active program"
          Just progIdx -> readRef p.input >>= \input -> case input of
              Nothing -> return unit
              Just (InputConnection ic) -> do
                s <- readRef (ic.input.slotVector `unsafeIndex` (ic.slotMapPipelineToInput `unsafeIndex` slotIdx))
                --trace $ "#" ++ show (length s.sortedObjects)
                for_ s.sortedObjects $ \(Tuple _ obj) -> do
                  enabled <- readRef obj.enabled
                  when enabled $ do
                    cmd <- readRef obj.commands
                    renderSlot $ (cmd `unsafeIndex` ic.id) `unsafeIndex` progIdx
      _ -> return unit

renderSlot :: [GLObjectCommand] -> GFX Unit
renderSlot cmds = do
  for_ cmds $ \cmd -> case cmd of
    GLSetVertexAttribArray idx buf size typ ptr -> do
      --trace $ "GLSetVertexAttribArray " ++ show [idx,size,ptr]
      GL.bindBuffer_ GL._ARRAY_BUFFER buf
      GL.enableVertexAttribArray_ idx
      GL.vertexAttribPointer_ idx size typ false 0 ptr
    GLDrawArrays mode first count -> do
      --trace $ "GLDrawArrays " ++ show [first,count]
      GL.drawArrays_ mode first count
    GLDrawElements mode count typ buf indicesPtr -> do
      --trace "GLDrawElements"
      GL.bindBuffer_ GL._ELEMENT_ARRAY_BUFFER buf
      GL.drawElements_ mode count typ indicesPtr
    GLSetVertexAttrib idx val -> do
      --trace $ "GLSetVertexAttrib " ++ show idx
      GL.disableVertexAttribArray_ idx
      setVertexAttrib idx val
    GLSetUniform idx uni -> do
      --trace "GLSetUniform"
      setUniform idx uni
{-
        GLBindTexture txTarget tuRef (GLUniform _ ref)  -> do
                                                            txObjVal <- readIORef ref
                                                            -- HINT: ugly and hacky
                                                            with txObjVal $ \txObjPtr -> do
                                                                txObj <- peek $ castPtr txObjPtr :: IO GLuint
                                                                texUnit <- readIORef tuRef
                                                                glActiveTexture $ gl_TEXTURE0 + fromIntegral texUnit
                                                                glBindTexture txTarget txObj
-}

disposePipeline :: WebGLPipeline -> GFX Unit
disposePipeline p = do
  setPipelineInput p Nothing
  for_ p.programs $ \prg -> do
      GL.deleteProgram_ prg.program
      traverse_ GL.deleteShader_ prg.shaders
  {- TODO: targets, textures
  let targets = glTargets p
  withArray (map framebufferObject $ V.toList targets) $ (glDeleteFramebuffers $ fromIntegral $ V.length targets)
  let textures = glTextures p
  withArray (map glTextureObject $ V.toList textures) $ (glDeleteTextures $ fromIntegral $ V.length textures)
  with (glVAO p) $ (glDeleteVertexArrays 1)
  -}

setPipelineInput :: WebGLPipeline -> Maybe WebGLPipelineInput -> GFX Unit
setPipelineInput p input' = do
    -- TODO: check matching input schema
    ic' <- readRef p.input
    case ic' of
        Nothing -> return unit
        Just (InputConnection ic) -> do
            modifyRef ic.input.pipelines $ \v -> updateAt ic.id Nothing v
            for_ ic.slotMapPipelineToInput $ \slotIdx -> do
                slot <- readRef (ic.input.slotVector `unsafeIndex` slotIdx)
                for_ (Map.values slot.objectMap) $ \obj -> do
                    modifyRef obj.commands $ \v -> updateAt ic.id [] v
    {-
        addition:
            - get an id from pipeline input
            - add to attached pipelines
            - generate slot mappings
            - update used slots, and generate object commands for objects in the related slots
    -}
    case input' of
        Nothing -> writeRef p.input Nothing
        Just input -> do
            oldPipelineV <- readRef input.pipelines
            Tuple idx shouldExtend <- case findIndex isNothing oldPipelineV of
                (-1) -> do
                    -- we don't have empty space, hence we double the vector size
                    let len = length oldPipelineV
                    modifyRef input.pipelines $ \v -> updateAt len (Just p) (concat [v,replicate len Nothing])
                    return $ Tuple len (Just len)
                i -> do
                    modifyRef input.pipelines $ \v -> updateAt i (Just p) v
                    return $ Tuple i Nothing
            -- create input connection
            pToI <- for p.slotNames $ \n -> case StrMap.lookup n input.slotMap of
              Nothing -> throwException $ error "internal error: unknown slot name in input"
              Just i -> return i
            let iToP = foldr (\(Tuple i v) -> updateAt v (Just i)) (replicate (StrMap.size input.slotMap) Nothing) (zip (0..length pToI) pToI)
            writeRef p.input $ Just $ InputConnection {id: idx, input: input, slotMapPipelineToInput: pToI, slotMapInputToPipeline: iToP}

            -- generate object commands for related slots
            {-
                for each slot in pipeline:
                    map slot name to input slot name
                    for each object:
                        generate command program vector => for each dependent program:
                            generate object commands
            -}
            let texUnitMap = {} --TODO: glTexUnitMapping p
                topUnis = input.uniformSetup
                emptyV  = replicate (length p.programs) []
                extend v = case shouldExtend of
                    Nothing -> v
                    Just l  -> concat [v,replicate l []]
            for_ (zip pToI p.slotPrograms) $ \(Tuple slotIdx prgs) -> do
                slot <- readRef $ input.slotVector `unsafeIndex` slotIdx
                for_ (Map.values slot.objectMap) $ \obj -> do
                    let updateCmds v prgIdx = updateAt prgIdx (createObjectCommands texUnitMap topUnis obj (p.programs `unsafeIndex` prgIdx)) v
                        cmdV = foldl updateCmds emptyV prgs
                    modifyRef obj.commands $ \v -> updateAt idx cmdV (extend v)
