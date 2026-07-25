#if canImport(UIKit)
import Foundation

final class SetActor<Option: SetAlgebra, ReactionType> {
    enum Action {
        case onEmpty, onChange, onInsertion(_ option: Option),
             onRemoval(_ option: Option)
    }

    enum ExecutionType {
        case once, eternal
    }

    final class Reaction {
        let type: ReactionType
        let action: Action
        let executionType: ExecutionType
        let actionBlock: () -> Void

        init(type: ReactionType,
             action: Action,
             executionType: ExecutionType = .once,
             actionBlock: @escaping () -> Void) {
            self.type = type
            self.action = action
            self.executionType = executionType
            self.actionBlock = actionBlock
        }
    }

    var options: Option {
        didSet {
            optionsChanged(oldOptions: oldValue)
        }
    }

    private(set) var reactions: [Reaction]

    init(options: Option = [], reactions: [Reaction] = []) {
        self.options = options
        self.reactions = reactions
        optionsChanged(oldOptions: [])
    }

    func add(reaction: Reaction) {
        reactions.append(reaction)
    }

    func remove(reaction: Reaction) {
        reactions.removeAll(where: { $0 === reaction })
    }

    func removeAllReactions(where shouldBeRemoved: (Reaction) throws -> Bool) throws {
        try reactions.removeAll(where: shouldBeRemoved)
    }

    func removeAllReactions() {
        reactions.removeAll()
    }

    private func optionsChanged(oldOptions: Option) {
        let reactions = reactions
        let onChangeReactions = reactions.filter {
            guard case .onChange = $0.action else {
                return false
            }
            return true
        }

        onChangeReactions.forEach { reaction in
            reaction.actionBlock()
            if reaction.executionType == .once {
                self.reactions.removeAll(where: { $0 === reaction })
            }
        }

        if options.isEmpty {
            let onEmptyReactions = reactions.filter {
                guard case .onEmpty = $0.action else {
                    return false
                }
                return true
            }
            onEmptyReactions.forEach { reaction in
                reaction.actionBlock()
                if reaction.executionType == .once {
                    self.reactions.removeAll(where: { $0 === reaction })
                }
            }
        }

        let insertedOptions = options.subtracting(oldOptions)
        for option in [insertedOptions] {
            let onEmptyReactions = reactions.filter {
                guard case let .onInsertion(newOption) = $0.action,
                      newOption == option else {
                    return false
                }
                return true
            }
            onEmptyReactions.forEach { reaction in
                reaction.actionBlock()
                if reaction.executionType == .once {
                    self.reactions.removeAll(where: { $0 === reaction })
                }
            }
        }

        let removedOptions = oldOptions.subtracting(options)
        for option in [removedOptions] {
            let onEmptyReactions = reactions.filter {
                guard case let .onRemoval(newOption) = $0.action,
                      newOption == option else {
                    return false
                }
                return true
            }
            onEmptyReactions.forEach { reaction in
                reaction.actionBlock()
                if reaction.executionType == .once {
                    self.reactions.removeAll(where: { $0 === reaction })
                }
            }
        }
    }
}

extension SetActor where ReactionType: Equatable {
    func removeAllReactions(_ type: ReactionType) {
        reactions.removeAll(where: { $0.type == type })
    }
}
#endif
