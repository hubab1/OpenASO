import Dispatch
import SwiftData

@ModelActor
actor BackgroundModelStore {
    private var worker: BackgroundModelContextWorker?

    func prepare() async {
        await contextWorker().prepare()
    }

    func read<Value: Sendable>(
        _ operation: @Sendable (ModelContext) throws -> Value
    ) async throws -> Value {
        try await contextWorker().read(operation)
    }

    func write<Value: Sendable>(
        _ operation: @Sendable (ModelContext) throws -> Value
    ) async throws -> Value {
        try await contextWorker().write(operation)
    }

    func fetch<Model: PersistentModel, Value: Sendable>(
        _ descriptor: FetchDescriptor<Model>,
        map transform: @Sendable ([Model]) throws -> Value
    ) async throws -> Value {
        try await contextWorker().fetch(descriptor, map: transform)
    }

    func fetchCount<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) async throws -> Int {
        try await contextWorker().fetchCount(descriptor)
    }

    private func contextWorker() -> BackgroundModelContextWorker {
        if let worker {
            return worker
        }

        let worker = BackgroundModelContextWorker(modelContainer: modelContainer)

        self.worker = worker
        return worker
    }
}

private actor BackgroundModelContextWorker {
    // SwiftData's default executor can run synchronous jobs on the caller's
    // thread. Own a serial queue so database I/O cannot borrow the UI thread.
    private nonisolated let executor = DispatchSerialQueue(
        label: "com.thirdtech.openaso.persistence",
        qos: .userInitiated,
        target: .global(qos: .userInitiated)
    )
    private let modelContainer: ModelContainer
    private var context: ModelContext?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func prepare() {
        _ = prepareModelContext()
    }

    private func prepareModelContext() -> ModelContext {
        if let context { return context }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.context = context
        return context
    }

    func read<Value: Sendable>(
        _ operation: @Sendable (ModelContext) throws -> Value
    ) throws -> Value {
        let modelContext = prepareModelContext()
        return try operation(modelContext)
    }

    func write<Value: Sendable>(
        _ operation: @Sendable (ModelContext) throws -> Value
    ) throws -> Value {
        let modelContext = prepareModelContext()
        do {
            let value = try operation(modelContext)
            try modelContext.save()
            return value
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func fetch<Model: PersistentModel, Value: Sendable>(
        _ descriptor: FetchDescriptor<Model>,
        map transform: @Sendable ([Model]) throws -> Value
    ) throws -> Value {
        let modelContext = prepareModelContext()
        let models = try modelContext.fetch(descriptor)
        return try transform(models)
    }

    func fetchCount<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws -> Int {
        let modelContext = prepareModelContext()
        return try modelContext.fetchCount(descriptor)
    }
}
