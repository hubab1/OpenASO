import SwiftData


@ModelActor
actor BackgroundModelStore {
    private var worker: BackgroundModelContextWorker?

    func prepare() async {
        _ = await contextWorker()
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

    private func contextWorker() async -> BackgroundModelContextWorker {
        if let worker {
            return worker
        }

        let modelContainer = modelContainer
        let worker = await Task.detached(priority: .utility) {
            BackgroundModelContextWorker(modelContainer: modelContainer)
        }.value

        self.worker = worker
        return worker
    }
}

@ModelActor
private actor BackgroundModelContextWorker {
    private func prepareModelContext() -> ModelContext {
        modelContext.autosaveEnabled = false
        return modelContext
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
