module Backend where

import Prelude
import qualified Control.Monad.Eff.Console as C
import Data.Maybe.Unsafe (fromJust)
import Data.Array.Unsafe (unsafeIndex)
import Data.Int.Bits

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
import qualified Data.StrMap.Unsafe as StrMap
import qualified Data.Map as Map
import Data.Tuple
import Data.Int
import Data.Maybe
import Data.Maybe.Unsafe
import Data.Array
import qualified Data.List as List
import Data.Function

import Type
import IR
import LinearBase
import Util
import Input
import Data

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
        PointSize s         -> C.error "PointSize is not supported!"

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
        runFn1 GL.lineWidth_ lw
        --setProvokingVertex pv

    cvt (TriangleCtx cm pm po pv) = do
        -- cull mode
        case cm of
            CullNone    -> runFn1 GL.disable_ GL._CULL_FACE
            CullFront f -> do
                runFn1 GL.enable_    GL._CULL_FACE
                runFn1 GL.cullFace_  GL._FRONT
                runFn1 GL.frontFace_ $ cff f
            CullBack f -> do
                runFn1 GL.enable_    GL._CULL_FACE
                runFn1 GL.cullFace_  GL._BACK
                runFn1 GL.frontFace_ $ cff f

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
        runFn1 GL.disable_ GL._POLYGON_OFFSET_FILL
        case po of
            NoOffset -> return unit
            Offset f u -> do
                runFn2 GL.polygonOffset_ f u
                runFn1 GL.enable_ GL._POLYGON_OFFSET_FILL

        -- provoking vertex
        -- not presented: setProvokingVertex pv

setupAccumulationContext :: AccumulationContext -> GFX Unit
setupAccumulationContext (AccumulationContext {accViewportName = n, accOperations = ops}) = cvt ops
  where
    cvt :: List.List FragmentOperation -> GFX Unit
    cvt (List.Cons (StencilOp a b c) (List.Cons (DepthOp f m) xs)) = do
        -- TODO
        cvtC 0 xs
    cvt (List.Cons (StencilOp a b c) xs) = do
        -- TODO
        cvtC 0 xs
    cvt (List.Cons (DepthOp df dm) xs) = do
        -- TODO
        runFn1 GL.disable_ GL._STENCIL_TEST
        let glDF = comparisonFunctionToGLType df
        case glDF == comparisonFunctionToGLType Always && dm == false of
            true    -> runFn1 GL.disable_ GL._DEPTH_TEST
            false   -> do
                runFn1 GL.enable_ GL._DEPTH_TEST
                runFn1 GL.depthFunc_ glDF
                runFn1 GL.depthMask_ dm
        cvtC 0 xs
    cvt xs = do 
        runFn1 GL.disable_ GL._DEPTH_TEST
        runFn1 GL.disable_ GL._STENCIL_TEST
        cvtC 0 xs

    cvtC :: Int -> List.List FragmentOperation -> GFX Unit
    cvtC i (List.Cons (ColorOp b m) xs) = do
        -- TODO
        case b of
            NoBlending -> do
                -- FIXME: requires GL 3.1
                --glDisablei gl_BLEND $ fromIntegral gl_DRAW_BUFFER0 + fromIntegral i
                runFn1 GL.disable_ GL._BLEND -- workaround
                -- not presented: GL.disable_ GL._COLOR_LOGIC_OP
            BlendLogicOp op -> do
                runFn1 GL.disable_ GL._BLEND
                -- not presented: GL.enable_  GL._COLOR_LOGIC_OP
                -- not presented: GL.logicOp_ $ logicOperationToGLType op
                C.log "not presented: BlendLogicOp"
            Blend blend -> do
                V4 r g b a <- return blend.color
                -- not presented: glDisable gl_COLOR_LOGIC_OP
                -- FIXME: requires GL 3.1
                --glEnablei gl_BLEND $ fromIntegral gl_DRAW_BUFFER0 + fromIntegral i
                runFn1 GL.enable_ GL._BLEND -- workaround
                runFn2 GL.blendEquationSeparate_ (blendEquationToGLType blend.colorEqSrc) (blendEquationToGLType blend.alphaEqSrc)
                runFn4 GL.blendColor_ r g b a
                runFn4 GL.blendFuncSeparate_ (blendingFactorToGLType blend.colorFSrc) (blendingFactorToGLType blend.colorFDst)
                                             (blendingFactorToGLType blend.alphaFSrc) (blendingFactorToGLType blend.alphaFDst)
        case m of
          VBool r           -> runFn4 GL.colorMask_ r true true true
          VV2B (V2 r g)     -> runFn4 GL.colorMask_ r g true true
          VV3B (V3 r g b)   -> runFn4 GL.colorMask_ r g b true
          VV4B (V4 r g b a) -> runFn4 GL.colorMask_ r g b a
          _                 -> runFn4 GL.colorMask_ true true true true
        cvtC (i + 1) xs
    cvtC _ List.Nil = return unit


clearRenderTarget :: Array ClearImage -> GFX Unit
clearRenderTarget values = do
    let setClearValue {mask:m,index:i} (ClearImage val) = case val of
            {imageSemantic = Depth, clearValue = VFloat v} -> do
                runFn1 GL.depthMask_ true
                runFn1 GL.clearDepth_ v
                return {mask:m .|. GL._DEPTH_BUFFER_BIT, index:i}
            {imageSemantic = Stencil, clearValue = VWord v} -> do
                runFn1 GL.clearStencil_ v
                return {mask:m .|. GL._STENCIL_BUFFER_BIT, index:i}
            {imageSemantic = Color, clearValue = c} -> do
                case c of
                  VFloat r            -> runFn4 GL.clearColor_ r 0.0 0.0 1.0
                  VV2F (V2 r g)       -> runFn4 GL.clearColor_ r g 0.0 1.0
                  VV3F (V3 r g b)     -> runFn4 GL.clearColor_ r g b 1.0
                  VV4F (V4 r g b a)   -> runFn4 GL.clearColor_ r g b a
                  _                   -> runFn4 GL.clearColor_ 0.0 0.0 0.0 1.0
                runFn4 GL.colorMask_ true true true true
                return {mask:m .|. GL._COLOR_BUFFER_BIT, index:i+1}
            _ -> throwException $ error "internal error (clearRenderTarget)"
    m <- foldM setClearValue {mask:0,index:0} values
    runFn1 GL.clear_ m.mask

compileProgram :: StrMap.StrMap InputType -> Program -> GFX GLProgram
compileProgram uniTrie (Program p) = do
    po <- runFn0 GL.createProgram_
    let createAndAttach src t = do
          o <- runFn1 GL.createShader_ t
          runFn2 GL.shaderSource_ o src
          runFn1 GL.compileShader_ o
          logStr <- runFn1 GL.getShaderInfoLog_ o
          C.log logStr
          status <- runFn2 GL.getShaderParameter_ o GL._COMPILE_STATUS
          when (status /= true) $ throwException $ error "compileShader failed!"
          runFn2 GL.attachShader_ po o
          --putStr "    + compile shader source: " >> printGLStatus
          return o

    objV <- createAndAttach p.vertexShader GL._VERTEX_SHADER
    objF <- createAndAttach p.fragmentShader GL._FRAGMENT_SHADER

    runFn1 GL.linkProgram_ po
    prgLog <- runFn1 GL.getProgramInfoLog_ po
    C.log prgLog

    -- check link status
    status <- runFn2 GL.getProgramParameter_ po GL._LINK_STATUS
    when (status /= true) $ throwException $ error "link program failed!"

    uniformLocation <- StrMap.fromList <$> for (StrMap.toList p.programUniforms) (\(Tuple uniName uniType) -> do
      loc <- runFn2 GL.getUniformLocation_ po uniName
      return $ Tuple uniName loc)

    samplerLocation <- StrMap.fromList <$> for (StrMap.toList p.programInTextures) (\(Tuple uniName uniType) -> do
      loc <- runFn2 GL.getUniformLocation_ po uniName
      return $ Tuple uniName loc)

    streamLocation <- StrMap.fromList <$> for (StrMap.toList p.programStreams) (\(Tuple streamName (Parameter s)) -> do
      loc <- runFn2 GL.getAttribLocation_ po streamName
      C.log $ "attrib location " ++ streamName ++" " ++ show loc
      return $ Tuple streamName {location: loc, slotAttribute: s.name})

    -- drop render textures, keep input textures
    let texUnis = filter (\n -> StrMap.member n uniTrie) $ StrMap.keys samplerLocation
    return { program: po
           , shaders: [objV,objF]
           , inputUniforms: uniformLocation
           , inputSamplers:samplerLocation
           , inputStreams: streamLocation
           , inputTextureUniforms: texUnis
           }

foreign import nullWebGLFramebuffer :: GL.WebGLFramebuffer

compileRenderTarget :: Array TextureDescriptor -> Array GLTexture -> RenderTarget -> GFX GLRenderTarget
compileRenderTarget texs glTexs (RenderTarget rt) = do
  let targets = rt.renderTargets
      isFB (Framebuffer _)    = true
      isFB _                  = false
      images = map (\(TargetItem a) -> fromJust a.targetRef) $ filter (\(TargetItem a) -> isJust a.targetRef) targets
      act1 = case all isFB images of
          true -> do
              let isColor Color = true
                  isColor _ = false
                  cvt (TargetItem a) = case a.targetRef of
                      Nothing                     -> return GL._NONE
                      Just (Framebuffer Color)    -> return GL._BACK
                      _                           -> throwException $ error "internal error (compileRenderTarget)!"
              bufs <- traverse cvt $ filter (\(TargetItem a) -> isColor a.targetSemantic) targets
              return $
                  { framebufferObject: nullWebGLFramebuffer
                  , framebufferDrawbuffers: Just bufs
                  }
          false -> do
              when (any isFB images) $ throwException $ error "internal error (compileRenderTarget)!"
              fbo <- runFn0 GL.createFramebuffer_
              runFn2 GL.bindFramebuffer_ GL._FRAMEBUFFER fbo
              let attach attachment (TextureImage texIdx level Nothing) = do
                      let glTex = glTexs `unsafeIndex` texIdx
                          tex = texs `unsafeIndex` texIdx
                          txLevel = level
                          txTarget = glTex.textureTarget
                          txObj = glTex.textureObject
                          attach2D = runFn5 GL.framebufferTexture2D_ GL._FRAMEBUFFER attachment txTarget txObj txLevel
                          act0 = case tex of
                            TextureDescriptor t -> case t.textureType of
                              Texture2D     _ 1 -> attach2D
                              _ -> throwException $ error "invalid texture format!"
                      act0
                  attach _ _ = throwException $ error "invalid texture format!"
                  go a (TargetItem {targetSemantic:Stencil, targetRef:Just img}) = do
                      throwException $ error "Stencil support is not implemented yet!"
                      return a
                  go a (TargetItem {targetSemantic: Depth,targetRef: Just img}) = do
                      attach GL._DEPTH_ATTACHMENT img
                      return a
                  go (Tuple bufs colorIdx) (TargetItem {targetSemantic: Color,targetRef: Just img}) = do
                      let attachment = GL._COLOR_ATTACHMENT0
                      attach attachment img
                      return (Tuple (attachment : bufs) (colorIdx + 1))
                  go (Tuple bufs colorIdx) (TargetItem {targetSemantic: Color,targetRef: Nothing}) = return (Tuple (GL._NONE : bufs) (colorIdx + 1))
                  go a _ = return a
              (Tuple bufs _) <- foldM go (Tuple [] 0) targets
              return $
                  { framebufferObject: fbo
                  , framebufferDrawbuffers: Nothing
                  }
  act1

compileStreamData :: StreamData -> GFX GLStream
compileStreamData (StreamData s) = do
  let compileAttr (VFloatArray v) = Array ArrFloat v
      compileAttr (VIntArray v) = Array ArrInt16 $ toArray v
      compileAttr (VWordArray v) = Array ArrWord16 $ toArray v
      --TODO: compileAttr (VBoolArray v) = Array ArrWord32 (length v) (withV withArray v)
  Tuple indexMap arrays <- return $ unzip $ map (\(Tuple i (Tuple n d)) -> Tuple (Tuple n i) (compileAttr d)) $ zip (0..(fromJust $ fromNumber $ StrMap.size s.streamData -1.0)) $ List.fromList $ StrMap.toList s.streamData
  let getLength n = do
        l <- case StrMap.lookup n s.streamData of
            Just (VFloatArray v) -> return $ length v
            Just (VIntArray v) -> return $ length v
            Just (VWordArray v) -> return $ length v
            _ -> throwException $ error "compileStreamData - getLength"
        c <- case StrMap.lookup n s.streamType of
            Just Float  -> return 1
            Just V2F    -> return 2
            Just V3F    -> return 3
            Just V4F    -> return 4
            Just M22F   -> return 4
            Just M33F   -> return 9
            Just M44F   -> return 16
            _ -> throwException $ error "compileStreamData - getLength element count"
        return $ l / c
  buffer <- compileBuffer arrays
  cmdRef <- newRef []
  let toStream (Tuple n i) = do
        t <- toStreamType =<< case StrMap.lookup n s.streamType of
          Just a -> return  a
          Nothing -> throwException $ error "compileStreamData - toStream"
        l <- getLength n
        return $ Tuple n (Stream
          { sType:  t
          , buffer: buffer
          , arrIdx: i
          , start:  0
          , length: l
          })
  strms <- traverse toStream indexMap
  return
    { commands: cmdRef
    , primitive: case s.streamPrimitive of
        Points    -> PointList
        Lines     -> LineList
        Triangles -> TriangleList
    , attributes: StrMap.fromList $ List.toList strms
    , program: fromJust $ head $ s.streamPrograms
    }

createStreamCommands :: StrMap.StrMap (Ref Int) -> StrMap.StrMap GLUniform -> StrMap.StrMap (Stream Buffer) -> Primitive -> GLProgram -> Array GLObjectCommand
createStreamCommands texUnitMap topUnis attrs primitive prg = streamUniCmds `append` streamCmds `append` [drawCmd]
  where
    -- object draw command
    drawCmd = GLDrawArrays prim 0 count
      where
        prim = primitiveToGLType primitive
        streamLen a = case a of
          Stream s  -> [s.length]
          _         -> []
        count = (concatMap streamLen $ List.fromList $ StrMap.values attrs) `unsafeIndex` 0

    -- object uniform commands
    -- texture slot setup commands
    streamUniCmds = uniCmds `append` texCmds
      where
        uniMap  = List.fromList $ StrMap.toList prg.inputUniforms
        topUni n = StrMap.unsafeIndex topUnis n
        uniCmds = flip map uniMap $ \(Tuple n i) -> GLSetUniform i $ topUnis `StrMap.unsafeIndex` n
        texCmds = flip map prg.inputTextureUniforms $ \n ->
          let u = topUni n
              texUnit = StrMap.unsafeIndex texUnitMap n
              txTarget = GL._TEXTURE_2D -- TODO
          in GLBindTexture txTarget texUnit u

    -- object attribute stream commands
    streamCmds = flip map (List.fromList $ StrMap.values prg.inputStreams) $ \is -> let
        s = attrs `StrMap.unsafeIndex` is.slotAttribute
        i = is.location
      in case s of
          Stream s -> let
              desc = s.buffer.arrays `unsafeIndex` s.arrIdx
              glType      = arrayTypeToGLType desc.arrType
              ptr compCnt = desc.arrOffset + s.start * compCnt * sizeOfArrayType desc.arrType
              setFloatAttrib n = GLSetVertexAttribArray i s.buffer.glBuffer n glType (ptr n)
            in setFloatAttrib $ case s.sType of
                TFloat  -> 1
                TV2F    -> 2
                TV3F    -> 3
                TV4F    -> 4
                TM22F   -> 4
                TM33F   -> 9
                TM44F   -> 16
            -- constant generic attribute
          constAttr -> GLSetVertexAttrib i constAttr

allocPipeline :: Pipeline -> GFX WebGLPipeline
allocPipeline (Pipeline p) = do
  -- enable extensions
  runFn1 GL.getExtension_ "WEBGL_depth_texture"
  texs <- traverse compileTexture p.textures
  trgs <- traverse (compileRenderTarget p.textures texs) p.targets
  prgs <- traverse (compileProgram StrMap.empty) p.programs
  texUnitMapRefs <- StrMap.fromFoldable <$> traverse (\k -> (Tuple k) <$> newRef 0) (nub $ concatMap (\(Program prg) -> StrMap.keys prg.programInTextures) p.programs)
  input <- newRef Nothing
  curProg <- newRef Nothing
  strms <- traverse compileStreamData p.streams
  return
    { targets: trgs
    , textures: texs
    , programs: prgs
    , commands: p.commands
    , input: input
    , slotPrograms: map (\(Slot a) -> a.slotPrograms) p.slots
    , slotNames: map (\(Slot a) -> a.slotName) p.slots
    , curProgram: curProg
    , texUnitMapping: texUnitMapRefs
    , streams: strms
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
                        runFn4 GL.viewport_ 0 0 w h
        -- TODO: set FBO target viewport
        runFn2 GL.bindFramebuffer_ GL._FRAMEBUFFER rt.framebufferObject
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
            Just i  -> case StrMap.lookup n p.texUnitMapping of
              Nothing -> throwException $ error "internal error (SetSamplerUniform)!"
              Just ref -> do
                writeRef ref tu
                runFn2 GL.uniform1i_ i tu

      SetTexture tu i -> do
        runFn1 GL.activeTexture_ (GL._TEXTURE0 + tu)
        let tx = p.textures `unsafeIndex` i
        runFn2 GL.bindTexture_ tx.textureTarget tx.textureObject
      SetRasterContext rCtx -> do
        --log "SetRasterContext"
        setupRasterContext rCtx
      SetAccumulationContext aCtx -> do
        --log "SetAccumulationContext"
        setupAccumulationContext aCtx
      ClearRenderTarget t -> do
        --log "ClearRenderTarget"
        clearRenderTarget t
      SetProgram i -> do
        --log $ "SetProgram " ++ show i
        writeRef p.curProgram (Just i)
        runFn1 GL.useProgram_ $ (p.programs `unsafeIndex` i).program
      RenderStream streamIdx -> do
        renderSlot =<< readRef (p.streams `unsafeIndex` streamIdx).commands
      RenderSlot slotIdx -> do
        --log $ "RenderSlot " ++ show slotIdx
        readRef p.curProgram >>= \cp -> case cp of
          Nothing -> throwException $ error "invalid pipeline, no active program"
          Just progIdx -> readRef p.input >>= \input -> case input of
              Nothing -> return unit
              Just (InputConnection ic) -> do
                s <- readRef (ic.input.slotVector `unsafeIndex` (ic.slotMapPipelineToInput `unsafeIndex` slotIdx))
                --log $ "#" ++ show (length s.sortedObjects)
                for_ s.sortedObjects $ \(Tuple _ obj) -> do
                  enabled <- readRef obj.enabled
                  when enabled $ do
                    cmd <- readRef obj.commands
                    renderSlot $ (cmd `unsafeIndex` ic.id) `unsafeIndex` progIdx
      _ -> return unit

renderSlot :: Array GLObjectCommand -> GFX Unit
renderSlot cmds = do
  for_ cmds $ \cmd -> case cmd of
    GLSetVertexAttribArray idx buf size typ ptr -> do
      --log $ "GLSetVertexAttribArray " ++ show [idx,size,ptr]
      runFn2 GL.bindBuffer_ GL._ARRAY_BUFFER buf
      runFn1 GL.enableVertexAttribArray_ idx
      runFn6 GL.vertexAttribPointer_ idx size typ false 0 ptr
    GLDrawArrays mode first count -> do
      --log $ "GLDrawArrays " ++ show [first,count]
      runFn3 GL.drawArrays_ mode first count
    GLDrawElements mode count typ buf indicesPtr -> do
      --log "GLDrawElements"
      runFn2 GL.bindBuffer_ GL._ELEMENT_ARRAY_BUFFER buf
      runFn4 GL.drawElements_ mode count typ indicesPtr
    GLSetVertexAttrib idx val -> do
      --log $ "GLSetVertexAttrib " ++ show idx
      runFn1 GL.disableVertexAttribArray_ idx
      setVertexAttrib idx val
    GLSetUniform idx uni -> do
      --log "GLSetUniform"
      setUniform idx uni
    GLBindTexture txTarget tuRef (UniFTexture2D ref) -> do
      TextureData txObj <- readRef ref
      texUnit <- readRef tuRef
      runFn1 GL.activeTexture_ $ GL._TEXTURE0 + texUnit
      runFn2 GL.bindTexture_ txTarget txObj

disposePipeline :: WebGLPipeline -> GFX Unit
disposePipeline p = do
  setPipelineInput p Nothing
  for_ p.programs $ \prg -> do
      runFn1 GL.deleteProgram_ prg.program
      traverse_ (runFn1 GL.deleteShader_) prg.shaders
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
            modifyRef ic.input.pipelines $ \v -> fromJust $ updateAt ic.id Nothing v
            for_ ic.slotMapPipelineToInput $ \slotIdx -> do
                slot <- readRef (ic.input.slotVector `unsafeIndex` slotIdx)
                for_ (Map.values slot.objectMap) $ \obj -> do
                    modifyRef obj.commands $ \v -> fromJust $ updateAt ic.id [] v
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
                Nothing -> do
                    -- we don't have empty space, hence we double the vector size
                    let len = length oldPipelineV
                    modifyRef input.pipelines $ \v -> fromJust $ updateAt len (Just p) (concat [v,replicate len Nothing])
                    return $ Tuple len (Just len)
                Just i -> do
                    modifyRef input.pipelines $ \v -> fromJust $ updateAt i (Just p) v
                    return $ Tuple i Nothing
            -- create input connection
            pToI <- for p.slotNames $ \n -> case StrMap.lookup n input.slotMap of
              Nothing -> throwException $ error "internal error: unknown slot name in input"
              Just i -> return i
            let iToP = foldr (\(Tuple i v) p -> fromJust $ updateAt v (Just i) p) (replicate (fromJust $ fromNumber $ StrMap.size input.slotMap) Nothing) (zip (0..length pToI) pToI)
            writeRef p.input $ Just $ InputConnection {id: idx, input: input, slotMapPipelineToInput: pToI, slotMapInputToPipeline: iToP}

            -- generate object commands for related slots
            {-
                for each slot in pipeline:
                    map slot name to input slot name
                    for each object:
                        generate command program vector => for each dependent program:
                            generate object commands
            -}
            let topUnis = input.uniformSetup
                emptyV  = replicate (length p.programs) []
                extend v = case shouldExtend of
                    Nothing -> v
                    Just l  -> concat [v,replicate l []]
            for_ (zip pToI p.slotPrograms) $ \(Tuple slotIdx prgs) -> do
                slot <- readRef $ input.slotVector `unsafeIndex` slotIdx
                for_ (Map.values slot.objectMap) $ \obj -> do
                    let updateCmds v prgIdx = fromJust $ updateAt prgIdx (createObjectCommands p.texUnitMapping topUnis obj (p.programs `unsafeIndex` prgIdx)) v
                        cmdV = foldl updateCmds emptyV prgs
                    modifyRef obj.commands $ \v -> fromJust $ updateAt idx cmdV (extend v)

            -- generate stream commands
            for_ p.streams $ \s -> do
              writeRef s.commands $ createStreamCommands p.texUnitMapping topUnis s.attributes s.primitive (p.programs `unsafeIndex` s.program)
