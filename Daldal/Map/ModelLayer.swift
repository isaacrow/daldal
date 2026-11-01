import CoreLocation
import MapLibre
import MetalKit
import ModelIO
import simd

/// Real 3D models drawn inside the map with Metal: the monuments at their true place and height, standing on the
/// ground and tilting and turning with the camera like the buildings around them, and (in Drive Mode) the car.
///
/// MapLibre's custom layers draw in "tile units": Web Mercator 0...1 scaled by 512 * 2^zoom, with heights in metres.
/// Each model's placement is combined with the map's projection in double precision on the CPU, so nothing jitters
/// when zoomed right in.
nonisolated final class ModelLayer: MLNCustomStyleLayer {
    /// A model on the map: where, which way it faces, and how big.
    struct Placement {
        var coordinate: CLLocationCoordinate2D
        /// Degrees clockwise from north.
        var heading: Double = 0
        /// Real height in metres of a model that is 1 unit tall.
        var height: Double
        /// Never drawn smaller than this many points tall (the car stays visible when zoomed out). 0 = true size only.
        var minimumPoints: Double = 0
    }

    /// Meshes ready on the GPU, by id.
    private var models: [String: GPUModel] = [:]
    /// Models added before MapLibre handed the layer its GPU.
    private var pending: [String: (MTLDevice) -> [MDLMesh]] = [:]
    private var placements: [String: Placement] = [:]

    private var device: MTLDevice?
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    /// First pass: the model's silhouette resets the depth behind it, so the map's own block of the same building
    /// can't poke through the real model.
    private var clearPipeline: MTLRenderPipelineState?
    private var clearDepthState: MTLDepthStencilState?
    private var whiteTexture: MTLTexture?

    // MARK: Public

    func set(_ id: String, placement: Placement?) {
        placements[id] = placement
        setNeedsDisplay()
    }

    func has(_ id: String) -> Bool { models[id] != nil }

    /// Loads a USDZ for an id (once). Call on the main thread; the GPU upload is quick.
    func load(_ id: String, from url: URL) {
        guard models[id] == nil, let device else { return }
        if let model = GPUModel(url: url, device: device) {
            models[id] = model
            setNeedsDisplay()
        }
    }

    /// Adds a model built in code (the car), with the layer's own GPU.
    func add(_ id: String, build: @escaping (MTLDevice) -> [MDLMesh]) {
        guard models[id] == nil else { return }
        guard let device else {
            pending[id] = build
            return
        }
        if let model = GPUModel(meshes: build(device), device: device) {
            models[id] = model
            setNeedsDisplay()
        }
    }

    // MARK: MapLibre

    override func didMove(to mapView: MLNMapView) {
        // MapLibre calls this on the main thread; take only the GPU and pixel format out of its resources.
        let (gpu, colorFormat) = MainActor.assumeIsolated { () -> ((any MTLDevice)?, MTLPixelFormat) in
            let resource = mapView.backendResource()
            return (resource.device, resource.mtkView.colorPixelFormat)
        }
        guard let device = gpu else { return }
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shaders, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "modelVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "modelFragment")
            descriptor.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(Self.vertexDescriptor)
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "modelClearDepth")
            descriptor.colorAttachments[0].writeMask = []
            clearPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            pipeline = nil
            clearPipeline = nil
        }
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)
        let clear = MTLDepthStencilDescriptor()
        clear.depthCompareFunction = .always
        clear.isDepthWriteEnabled = true
        clearDepthState = device.makeDepthStencilState(descriptor: clear)

        let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        whiteTexture = device.makeTexture(descriptor: texture)
        var white: [UInt8] = [255, 255, 255, 255]
        whiteTexture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)

        let waiting = pending
        pending = [:]
        for (id, build) in waiting { add(id, build: build) }
    }

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        guard let encoder = renderEncoder, let pipeline, let depthState else { return }
        let worldSize = 512.0 * pow(2.0, context.zoomLevel)
        let projection = Self.matrix(context.projectionMatrix)
        encoder.setCullMode(.none)

        var visible: [(GPUModel, Uniforms)] = []
        for (id, placement) in placements {
            guard let model = models[id] else { continue }
            let c = placement.coordinate
            let mercatorX = (c.longitude + 180) / 360
            let mercatorY = (1 - log(tan(.pi / 4 + c.latitude * .pi / 360)) / .pi) / 2
            // Tile units per metre at this latitude.
            let unitsPerMetre = worldSize / (40_075_016.686 * cos(c.latitude * .pi / 180))
            var metres = placement.height
            if placement.minimumPoints > 0 {
                metres = max(metres, placement.minimumPoints / unitsPerMetre)
            }
            let s = metres * unitsPerMetre
            let yaw = placement.heading * .pi / 180
            // Model space: x east, y up, z south (1 unit = the model's height). Map space: x east, y south (tile
            // units), z up (metres).
            let place = simd_double4x4(columns: (
                SIMD4(cos(yaw) * s, sin(yaw) * s, 0, 0),
                SIMD4(0, 0, metres, 0),
                SIMD4(-sin(yaw) * s, cos(yaw) * s, 0, 0),
                SIMD4(mercatorX * worldSize, mercatorY * worldSize, 0, 1)))
            let m = projection * place
            let matrix = simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
                                                 SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
            visible.append((model, Uniforms(matrix: matrix, light: simd_normalize(SIMD3<Float>(-0.4, 0.85, -0.35)))))
        }
        if let clearPipeline, let clearDepthState {
            encoder.setRenderPipelineState(clearPipeline)
            encoder.setDepthStencilState(clearDepthState)
            for (model, uniforms) in visible { drawMeshes(model, uniforms, encoder) }
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        for (model, uniforms) in visible { drawMeshes(model, uniforms, encoder) }
    }

    private func drawMeshes(_ model: GPUModel, _ uniforms: Uniforms, _ encoder: MTLRenderCommandEncoder) {
        var uniforms = uniforms
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        for mesh in model.meshes {
            for (index, buffer) in mesh.vertexBuffers.enumerated() {
                encoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: index == 0 ? 0 : 2 + index)
            }
            for part in mesh.parts {
                var colour = part.colour
                encoder.setFragmentBytes(&colour, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setFragmentTexture(part.texture ?? whiteTexture, index: 0)
                encoder.drawIndexedPrimitives(type: part.submesh.primitiveType, indexCount: part.submesh.indexCount,
                                              indexType: part.submesh.indexType, indexBuffer: part.submesh.indexBuffer.buffer,
                                              indexBufferOffset: part.submesh.indexBuffer.offset)
            }
        }
    }

    // MARK: Plumbing

    struct Uniforms {
        var matrix: simd_float4x4
        var light: SIMD3<Float>
    }

    nonisolated(unsafe) static let vertexDescriptor: MDLVertexDescriptor = {
        let d = MDLVertexDescriptor()
        d.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        d.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        d.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        d.layouts[0] = MDLVertexBufferLayout(stride: 32)
        return d
    }()

    private static func matrix(_ m: MLNMatrix4) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4(m.m00, m.m01, m.m02, m.m03), SIMD4(m.m10, m.m11, m.m12, m.m13),
                                 SIMD4(m.m20, m.m21, m.m22, m.m23), SIMD4(m.m30, m.m31, m.m32, m.m33)))
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float2 uv [[attribute(2)]];
    };
    struct Uniforms { float4x4 matrix; float3 light; };
    struct VertexOut { float4 position [[position]]; float2 uv; float shade; };

    vertex VertexOut modelVertex(VertexIn in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        VertexOut out;
        out.position = u.matrix * float4(in.position, 1.0);
        out.uv = in.uv;
        // Soft daylight: a sun from the south-west plus sky light, so domes and walls read in any camera angle.
        out.shade = 0.55 + 0.45 * abs(dot(normalize(in.normal), u.light));
        return out;
    }

    struct DepthOut { float depth [[depth(any)]]; };

    fragment DepthOut modelClearDepth(VertexOut in [[stage_in]]) {
        DepthOut out;
        out.depth = 1.0;
        return out;
    }

    fragment float4 modelFragment(VertexOut in [[stage_in]], constant float4 &colour [[buffer(0)]],
                                  texture2d<float> texture [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::repeat);
        float4 base = texture.sample(s, in.uv) * colour;
        return float4(base.rgb * in.shade, 1.0);
    }
    """
}

/// A model's meshes uploaded to the GPU, each part with its colour or texture.
nonisolated private struct GPUModel {
    struct Part {
        let submesh: MTKSubmesh
        let colour: SIMD4<Float>
        let texture: MTLTexture?
    }

    struct Mesh {
        let vertexBuffers: [MTKMeshBuffer]
        let parts: [Part]
    }

    let meshes: [Mesh]

    init?(url: URL, device: MTLDevice) {
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: url, vertexDescriptor: ModelLayer.vertexDescriptor, bufferAllocator: allocator)
        asset.loadTextures()
        guard let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh], !meshes.isEmpty else { return nil }
        // Scene-node transforms into the vertices, then stand the model on the ground, centred, 1 unit tall.
        for mesh in meshes {
            let global = MDLTransform.globalTransform(with: mesh, atTime: 0)
            mesh.vertexDescriptor = ModelLayer.vertexDescriptor
            CarMesh.transform(mesh, by: global)
            mesh.transform = nil
        }
        CarMesh.normalise(meshes)
        self.init(meshes: meshes, device: device)
    }

    init?(meshes source: [MDLMesh], device: MTLDevice) {
        let loader = MTKTextureLoader(device: device)
        var built: [Mesh] = []
        for mdl in source {
            // Bake each mesh's own transform (USD scene nodes) into its vertices, in the layer's layout.
            mdl.vertexDescriptor = ModelLayer.vertexDescriptor
            guard let mesh = try? MTKMesh(mesh: mdl, device: device) else { continue }
            let submeshes = (mdl.submeshes as? [MDLSubmesh]) ?? []
            let parts = zip(mesh.submeshes, submeshes).map { gpu, cpu -> Part in
                var colour = SIMD4<Float>(0.85, 0.82, 0.76, 1)
                var texture: MTLTexture?
                if let base = cpu.material?.property(with: .baseColor) {
                    switch base.type {
                    case .float3: colour = SIMD4(base.float3Value, 1)
                    case .float4: colour = base.float4Value
                    case .color: if let c = base.color, let comps = c.components, comps.count >= 3 {
                        colour = SIMD4(Float(comps[0]), Float(comps[1]), Float(comps[2]), 1)
                    }
                    case .texture:
                        if let mdlTexture = base.textureSamplerValue?.texture {
                            texture = try? loader.newTexture(texture: mdlTexture, options: [.SRGB: false, .generateMipmaps: true])
                            colour = SIMD4(1, 1, 1, 1)
                        }
                    default: break
                    }
                }
                return Part(submesh: gpu, colour: colour, texture: texture)
            }
            built.append(Mesh(vertexBuffers: mesh.vertexBuffers, parts: parts))
        }
        guard !built.isEmpty else { return nil }
        meshes = built
    }
}

/// A smooth, Tesla-style car built from rounded shapes: a low pearl-white body, a dark glass canopy, dark wheels.
/// 1 unit = its height (1.45 m); it faces north (-z) before the heading turns it.
nonisolated enum CarMesh {
    static func meshes(device: MTLDevice) -> [MDLMesh] {
        let allocator = MTKMeshBufferAllocator(device: device)
        func material(_ r: Float, _ g: Float, _ b: Float) -> MDLMaterial {
            let m = MDLMaterial(name: "paint", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
            m.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: SIMD3(r, g, b)))
            return m
        }
        func shape(_ mesh: MDLMesh, at offset: SIMD3<Float>, colour: MDLMaterial) -> MDLMesh {
            let t = MDLTransform()
            t.translation = offset
            mesh.transform = t
            (mesh.submeshes as? [MDLSubmesh])?.forEach { $0.material = colour }
            return mesh
        }
        // Dimensions in units of the car's height (1.45 m): 4.7 m long, 1.9 m wide.
        let length: Float = 4.7 / 1.45, width: Float = 1.9 / 1.45
        // A low, smooth pod (a flattened ellipsoid) reads as a modern EV from above and behind.
        let body = MDLMesh(sphereWithExtent: SIMD3(width, 0.72, length), segments: SIMD2(32, 16),
                           inwardNormals: false, geometryType: .triangles, allocator: allocator)
        let canopy = MDLMesh(sphereWithExtent: SIMD3(width * 0.84, 0.62, length * 0.55), segments: SIMD2(24, 16),
                             inwardNormals: false, geometryType: .triangles, allocator: allocator)
        var parts = [
            shape(body, at: [0, 0.42, 0], colour: material(0.95, 0.95, 0.96)),
            shape(canopy, at: [0, 0.66, 0.05 * length], colour: material(0.06, 0.07, 0.09)),
        ]
        for (x, z) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] as [(Float, Float)] {
            let wheel = MDLMesh(cylinderWithExtent: SIMD3(0.48, 0.17, 0.48), segments: SIMD2(18, 1), inwardNormals: false,
                                topCap: true, bottomCap: true, geometryType: .triangles, allocator: allocator)
            let t = MDLTransform()
            t.translation = [x * width * 0.45, 0.24, z * length * 0.32]
            t.rotation = [0, 0, .pi / 2]
            wheel.transform = t
            (wheel.submeshes as? [MDLSubmesh])?.forEach { $0.material = material(0.1, 0.1, 0.11) }
            parts.append(wheel)
        }
        // Bake transforms into vertices (MTKMesh ignores node transforms).
        for part in parts {
            part.vertexDescriptor = ModelLayer.vertexDescriptor
            if let matrix = part.transform?.matrix { transform(part, by: matrix) }
            part.transform = nil
        }
        normalise(parts)
        return parts
    }

    /// Moves meshes together so they stand on y = 0, centred on x/z, exactly 1 unit tall.
    static func normalise(_ meshes: [MDLMesh]) {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for mesh in meshes {
            guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
            for i in 0..<mesh.vertexCount {
                let p = positions.dataStart.advanced(by: i * positions.stride).assumingMemoryBound(to: Float.self)
                let v = SIMD3(p[0], p[1], p[2])
                low = simd_min(low, v)
                high = simd_max(high, v)
            }
        }
        let height = high.y - low.y
        guard height > 0 else { return }
        let scale = 1 / height
        var matrix = matrix_identity_float4x4
        matrix.columns.0.x = scale
        matrix.columns.1.y = scale
        matrix.columns.2.z = scale
        matrix.columns.3 = SIMD4(-(low.x + high.x) / 2 * scale, -low.y * scale, -(low.z + high.z) / 2 * scale, 1)
        for mesh in meshes { transform(mesh, by: matrix) }
    }

    /// Applies a matrix to a mesh's positions and normals, in place.
    static func transform(_ mesh: MDLMesh, by transform: simd_float4x4) {
        guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3),
              let normals = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) else { return }
        let normalMatrix = simd_float3x3(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                                         SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                                         SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        // Three plain floats each: SIMD3<Float> is 16 bytes and would spill into the next attribute.
        for i in 0..<mesh.vertexCount {
            let p = positions.dataStart.advanced(by: i * positions.stride).assumingMemoryBound(to: Float.self)
            let moved = transform * SIMD4(p[0], p[1], p[2], 1)
            p[0] = moved.x; p[1] = moved.y; p[2] = moved.z
            let n = normals.dataStart.advanced(by: i * normals.stride).assumingMemoryBound(to: Float.self)
            let turned = simd_normalize(normalMatrix * SIMD3(n[0], n[1], n[2]))
            n[0] = turned.x; n[1] = turned.y; n[2] = turned.z
        }
    }
}
