//
//  GameDomain.swift
//  Bomb
//
//  Created by Илья Шаповалов on 07.08.2023.
//

import Foundation
import Combine
import OSLog

struct GameDomain {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )
    
    //MARK: - State
    struct State: Equatable, Codable {
        var title: String = .init()
        var quest: String = .init()
        var questsArray: [String] = ["Who are you?", "Fuck off."]
        var questionCategory: CategoryName = .varied
        var counter: Int = .init()
        var estimatedTime: Int = 10
        var gameFlow: GameFlow = .init()
        var backgroundMelody: Settings.Melody = .melody1
        var tickSound: Settings.Melody = .melody1
        var explosionSound: Settings.Melody = .melody1
        var isShowSheet = false
    }
    
    //MARK: - Action
    enum Action: Equatable {
        case setupGame
        case setGameState(State.GameFlow)
        case launchButtonTap(Settings)
        case pauseButtonTap
        case timerTick
        case playAgainButtonTap
        case anotherPunishmentButtonTap
        case dismissSheet
        case viewDisappear
        case questionResponse(Result<String, Error>)
        
        static func == (lhs: GameDomain.Action, rhs: GameDomain.Action) -> Bool {
            String(describing: lhs) == String(describing: rhs)
        }
    }
    
    //MARK: - Dependencies
    private let timerService: TimerProtocol
    private let player: AudioPlayerProtocol
    private let randomNumber: (Int) -> Int
    private let questions: () -> AnyPublisher<[CategoryQuests], Error>
    
    //MARK: - init(_:)
    init(
        timerService: TimerProtocol = TimerService(),
        player: AudioPlayerProtocol = AudioPlayer(),
        randomNumber: @escaping (Int) -> Int = { Int.random(in: 0..<$0) },
        questions: @escaping () -> AnyPublisher<[CategoryQuests], Error> = AppFileManager.live.loadQuestions
    ) {
        self.timerService = timerService
        self.player = player
        self.randomNumber = randomNumber
        self.questions = questions
        
        logger.debug("Initialized")
    }
    
    //MARK: - Reducer
    func reduce(_ state: inout State, action: Action) -> AnyPublisher<Action, Never> {
        switch action {
        case .setupGame:
            let currentState = state
            logger.debug("Setup game. Current state: \(String(reflecting: currentState))")
            
            return Publishers.Concatenate(
                prefix: Just(Action.setGameState(state.gameFlow)),
                suffix: timerService.timerTick.map { _ in .timerTick }
            )
            .eraseToAnyPublisher()
            
        case .setGameState(.initial):
            logger.debug("Setup game state to initial")
            state.counter = 0
            state.isShowSheet = false
            player.stop()
            state.gameFlow = .initial
            
            return questions()
                .compactMap{ [name = state.questionCategory] in filter(categories: $0, by: name) }
                .map(\.quests)
                .compactMap{ $0.randomElement() }
                .map(transformToSuccessAction)
                .catch(catchToFailAction)
                .eraseToAnyPublisher()
            
        case .setGameState(.play):
            logger.debug("Setup game state to play")
            player.playTicking(state.tickSound)
            player.playBackgroundMusic(state.backgroundMelody)
            timerService.startTimer()
            state.gameFlow = .play
            
        case .setGameState(.pause):
            logger.debug("Setup game state to pause")
            player.stop()
            timerService.stopTimer()
            state.gameFlow = .pause
            
        case .setGameState(.explosion):
            logger.debug("Setup game state to explosion")
            state.gameFlow = .explosion
            timerService.stopTimer()
            player.stop()
            player.playExplosion(state.explosionSound)
            
            return Just(.setGameState(.gameOver))
                .eraseToAnyPublisher()
            
        case .setGameState(.gameOver):
            logger.debug("Setup game state to gameOver")
            state.gameFlow = .gameOver
            state.quest = getRandomElement(from: state.questsArray)
            state.isShowSheet = true
            
        case .timerTick:
            guard state.counter < state.estimatedTime else {
                return Just(.setGameState(.explosion))
                    .eraseToAnyPublisher()
            }
            state.counter += 1
            
        case let .launchButtonTap(settings):
            state.estimatedTime = settings.duration.duration
            state.backgroundMelody = settings.backgroundMelody
            state.tickSound = settings.tickSound
            state.explosionSound = settings.explosionSound
            
            return Just(.setGameState(.play))
                .eraseToAnyPublisher()
            
        case .pauseButtonTap:
            return Just(state)
                .map(\.gameFlow)
                .map(togglePause)
                .compactMap { $0 }
                .eraseToAnyPublisher()
            
        case .playAgainButtonTap:
            return Just(.setGameState(.initial))
                .eraseToAnyPublisher()
            
        case .anotherPunishmentButtonTap:
            state.quest = getRandomElement(from: state.questsArray)
            
        case let .questionResponse(.success(quest)):
            state.quest = quest
            
        case let .questionResponse(.failure(error)):
            state.quest = error.localizedDescription
            logger.error("Unable to load quest: \(String(describing: error))")
        
            
        case .viewDisappear:
            defer {
                timerService.stopTimer()
                player.stop()
            }
            
            return Just(.setGameState(.initial))
                .eraseToAnyPublisher()
            
        case .dismissSheet:
            state.isShowSheet = false
        }
        
        return Empty().eraseToAnyPublisher()
    }
    
    //MARK: - Live store
    static let liveStore = GameStore(
        initialState: Self.State(),
        reducer: Self()
    )
    
    //MARK: - Preview stores
    static let previewStoreInitialState = GameStore(
        initialState: Self.State(
            title: "Нажмите запустить, чтобы начать игру",
            estimatedTime: 10,
            gameFlow: .initial
        ),
        reducer: Self(questions: AppFileManager.preview.loadQuestions)
    )
    
    static let previewStorePlayState = GameStore(
        initialState: Self.State(
            title: "Some question",
            gameFlow: .play
        ),
        reducer: Self(questions: AppFileManager.preview.loadQuestions)
    )
    
    static let previewStorePauseState = GameStore(
        initialState: Self.State(
            title: "Pause",
            gameFlow: .pause
        ),
        reducer: Self(questions: AppFileManager.preview.loadQuestions)
    )
    
    static let previewStoreGameOverState = GameStore(
        initialState: Self.State(
            title: "Конец игры",
            quest: "В следующем раунде, после каждого ответа, хлопать в ладоши",
            gameFlow: .gameOver,
            isShowSheet: true
        ),
        reducer: Self(questions: AppFileManager.preview.loadQuestions)
    )
}

private extension GameDomain {
    func getRandomElement(from collection: [String]) -> String {
        let randomIndex = randomNumber(collection.count)
        return collection[randomIndex]
    }
    
    func togglePause(_ gameFlow: State.GameFlow) -> Action? {
        switch gameFlow {
        case .play:
            return .setGameState(.pause)
        case .pause:
            return .setGameState(.play)
        default:
            return nil
        }
    }
    
    func filter(categories: [CategoryQuests], by name: CategoryName) -> CategoryQuests? {
        categories.first(where: { $0.category == name })
    }
    
    func transformToSuccessAction(_ quest: String) -> Action {
        .questionResponse(.success(quest))
    }
    
    func catchToFailAction(_ error: Error) -> Just<Action> {
        Just(.questionResponse(.failure(error)))
    }
}

extension GameDomain.State {
    enum GameFlow: Codable {
        case initial
        case play
        case pause
        case explosion
        case gameOver
        
        init() {
            self = .initial
        }
    }
}
