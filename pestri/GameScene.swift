import SpriteKit
import CoreMotion
import MultipeerConnectivity

class GameScene: SKScene {
    
    enum GameMode {
        case Offline
        case Server
        case Client
    }
    
    var parentView : GameViewController!
    
    var world : SKNode!
    var foodLayer : SKNode!
    var virusLayer : SKNode!
    var playerLayer : SKNode!
    var hudLayer : Hud!
    
    var currentPlayer: Player? = nil
    var rank : [Dictionary<String, Any>] = []
    var playerName = ""
    var splitButton : SKSpriteNode!
    var currentMass : SKLabelNode!
    
    var touchingLocation : UITouch? = nil
    var motionManager : CMMotionManager!
    var motionDetectionIsEnabled = false
    
    var previousChildrenCount = 0
    var previousTotalMass: CGFloat = 0.0
    
    // Menus
    var pauseMenu : PauseView!
    var gameOverMenu : GameOverView!
    
    var gameMode : GameMode! = GameMode.Offline
    
    // Multipeer variables
    var clientDelegate : ClientSessionDelegate!
    var serverDelegate : ServerSessionDelegate!
    
    override func didMoveToView(view: SKView) {
        paused = true
        self.view?.multipleTouchEnabled = true
        
        // Prepare multipeer connectivity
        clientDelegate = ClientSessionDelegate(scene: self)
        serverDelegate = ServerSessionDelegate(scene: self)
        
        world = self.childNodeWithName("world")!
        foodLayer = world.childNodeWithName("foodLayer")
        virusLayer = world.childNodeWithName("virusLayer")
        playerLayer = world.childNodeWithName("playerLayer")
        
        /* Setup your scene here */
        world.position = CGPoint(x: CGRectGetMidX(frame),
            y: CGRectGetMidY(frame))
 
        // Setup Hud
        hudLayer = Hud(hudWidth: self.frame.width, hudHeight: self.frame.height)
        self.addChild(hudLayer)
        physicsWorld.contactDelegate = self
        
        // Setup pause menu and death menu
        pauseMenu = PauseView(frame: self.frame, scene: self)
        self.view!.addSubview(pauseMenu)
        gameOverMenu = GameOverView(frame: self.frame, scene: self)
        self.view!.addSubview(gameOverMenu)
        
        // Device motion detector
        motionManager = CMMotionManager()
    }
    
    func cleanAll() {
        foodLayer.removeAllChildren()
        virusLayer.removeAllChildren()
        playerLayer.removeAllChildren()
        
        self.removeAllActions()
    }
    
    func start(gameMode : GameMode = GameMode.Offline) {
        
        self.gameMode = gameMode
        
        cleanAll()
        
        scheduleRunRepeat(self, time: Double(GlobalConstants.LeaderboardUpdateInterval)) { () -> Void in
            self.updateLeaderboard()
        }
        
        if gameMode == GameMode.Offline || gameMode == GameMode.Server {
            // Create Foods
            self.spawnFood(100)
            // Create Virus
            self.spawnVirus(15)
            
            scheduleRunRepeat(self, time: Double(GlobalConstants.VirusRespawnInterval)) { () -> Void in
                if self.virusLayer.children.count < GlobalConstants.VirusLimit {
                    self.spawnVirus()
                }
            }
            
            self.currentPlayer = Player(playerName: playerName, parentNode: self.playerLayer)
        }
        
        // Spawn AI for single player mode
        if gameMode == GameMode.Offline {
            for _ in 0..<4 {
                let _ = StupidPlayer(playerName: "Stupid AI", parentNode: self.playerLayer)
            }
            for _ in 0..<4 {
                let _ = AIPlayer(playerName: "Smarter AI", parentNode: self.playerLayer)
            }
        } else {
            if gameMode == GameMode.Server {
                scheduleRunRepeat(self, time: Double(GlobalConstants.BroadcastInterval)) { () -> Void in
                    self.serverDelegate.broadcast()
                }
            } else {
                clientDelegate.requestSpawn()
            }
        }
        
        self.updateLeaderboard()
        
        paused = false
    }
    
    func pauseGame() {
        self.pauseMenu.hidden = false
        
        // Only pause in SP mode
        if gameMode == GameMode.Offline {
            self.paused = true
        }
    }
    
    func continueGame() {
        self.pauseMenu.hidden = true
        self.paused = false
    }
    
    func abortGame() {
        self.paused = true
        self.pauseMenu.hidden = true
        self.gameOverMenu.hidden = true
        GameKitHelper.sharedInstance.disconnect()
        self.parentView.navigationController?.popViewControllerAnimated(true)
    }
    
    func gameOver() {
        self.gameOverMenu.hidden = false
    }
    
    func respawn() {
        self.paused = false
        self.gameOverMenu.hidden = true
        if gameMode == GameMode.Offline || gameMode == GameMode.Server {
            if currentPlayer == nil || currentPlayer!.isDead() {
                currentPlayer = Player(playerName: playerName, parentNode: self.playerLayer)
                currentPlayer!.children.first!.position = randomPosition()
            }
        } else {
            // Send request to server
            self.clientDelegate.requestSpawn()
        }
    }
    
    func spawnFood(n : Int = 1) {
        for _ in 0..<n {
            foodLayer.addChild(Food(foodColor: randomColor()))
        }
    }
    
    func spawnVirus(n : Int = 1) {
        for _ in 0..<n {
            virusLayer.addChild(Virus())
        }
    }
    
    func updateLeaderboard() {
        rank = []
        for player in playerLayer.children as! [Player] {
            rank.append([
                "name": player.displayName,
                "score": player.totalMass()
            ])
        }
        
        rank.sortInPlace({$0["score"] as! CGFloat > $1["score"] as! CGFloat})

        hudLayer.setLeaderboard(rank)
    }
    
    func centerWorldOnPosition(position: CGPoint) {
        let screenLocation = self.convertPoint(position, fromNode: world)
        let screenCenter = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame))
        world.position = world.position - screenLocation + screenCenter
    }
    
    func scaleWorldBasedOnPlayer(player : Player) {
        if player.children.count == 0 || player.totalMass() == 0 {
            world.setScale(1.0)
            return
        }

        if player.children.count != self.previousChildrenCount || player.totalMass() != self.previousTotalMass {
            self.previousChildrenCount = player.children.count
            self.previousTotalMass = player.totalMass()
            let scaleFactorBallNumber = 1.0 + (log(CGFloat(player.children.count)) - 1) * 0.2
            let t = log10(CGFloat(player.totalMass())) - 1
            let scaleFactorBallMass = 1.0 + t * t * 1.0
            world.setScale(1 / scaleFactorBallNumber / scaleFactorBallMass)
        }
    }
    
    func motionDetection() -> CGVector? {
        if motionDetectionIsEnabled {
            if let motion = motionManager.deviceMotion {
                //motion.attitude.yaw
                let m = motion.attitude.rotationMatrix
                let x = Vector3D(x: m.m11, y: m.m12, z: m.m13)
                let y = Vector3D(x: m.m21, y: m.m22, z: m.m23)
                let z = Vector3D(x: m.m31, y: m.m32, z: m.m33)
            
                let g = Vector3D(x: 0.0, y: 0.0, z: -1.0)
                let pl = dot(z, rhs: g)
                var d = g - z * pl
                d = d / d.length()
            
                let nd = CGVector(dx: dot(d, rhs: y), dy: -1.0 * dot(d, rhs: x))
                let maxv : CGFloat = 10000.0
                return nd * maxv
            }
            return nil
        }
        return nil
    }
    
    override func didSimulatePhysics() {

        world.enumerateChildNodesWithName("//ball*", usingBlock: {
            node, stop in
            let ball = node as! Ball
            ball.regulateSpeed()
        })
        
        if let p = currentPlayer {
            centerWorldOnPosition(p.centerPosition())
        } else if playerLayer.children.count > 0 {
            let p = playerLayer.children.first! as! Player
            centerWorldOnPosition(p.centerPosition())
        } else {
            centerWorldOnPosition(CGPoint(x: 0, y: 0))
        }
    }
   
    override func update(currentTime: CFTimeInterval) {
        if paused {
            return
        }
        
        if gameMode == GameMode.Client {
            clientDelegate.updateScene()
        } else {
            // Respawn food and virus
            let foodRespawnNumber = min(GlobalConstants.FoodLimit - foodLayer.children.count, GlobalConstants.FoodRespawnRate)
            spawnFood(foodRespawnNumber)
        }
        
        if currentPlayer != nil {
            if let v = motionDetection() {
                let c = currentPlayer!.centerPosition()
                let p = CGPoint(x: c.x + v.dx, y: c.y + v.dy)
                if gameMode == GameMode.Client {
                    clientDelegate.requestMove(p)
                }
                currentPlayer!.move(p)
            } else if let t = touchingLocation {
                let p = t.locationInNode(world)
                if gameMode == GameMode.Client {
                    clientDelegate.requestMove(p)
                }
                currentPlayer!.move(p)
            } else {
                if gameMode == GameMode.Client {
                    clientDelegate.requestFloating()
                }
                currentPlayer!.floating()
            }
            
            
        } else {
            // Send request to server
        }
        
        for var i = playerLayer.children.count - 1; i >= 0; i -= 1 {
            let p = playerLayer.children[i] as! Player
            p.checkDeath()
        }
        
        if currentPlayer != nil && currentPlayer!.isDead() {
            self.gameOver()
            currentPlayer = nil
        }
        
        for p in playerLayer.children as! [Player] {
            p.refreshState()
        }
        
        if currentPlayer != nil {
            hudLayer.setScore(currentPlayer!.totalMass())
            scaleWorldBasedOnPlayer(currentPlayer!)
        } else if playerLayer.children.count > 0 {
            scaleWorldBasedOnPlayer(playerLayer.children.first! as! Player)
        } else {
            world.setScale(1.0)
        }
    }
    
    override func touchesBegan(touches: Set<UITouch>, withEvent event: UIEvent?) {
        if touches.count <= 0 || paused {
            return
        }
        
        for touch in touches {
            let screenLocation = touch.locationInNode(self)
            if self.hudLayer.splitBtn.containsPoint(screenLocation) {
                if currentPlayer != nil {
                    currentPlayer!.split()
                    if gameMode == GameMode.Client {
                        clientDelegate.requestSplit()
                    }
                }
            } else if self.hudLayer.pauseBtn.containsPoint(screenLocation) {
                self.pauseGame()
            } else {
                touchingLocation = touch
            }
        }
        
        self.updateSplitButtonPosition()
    }
    
    override func touchesMoved(touches: Set<UITouch>, withEvent event: UIEvent?) {
        if touches.count <= 0 || paused {
            return
        }
        
        for touch in touches {
            let screenLocation = touch.locationInNode(self)
            if self.hudLayer.splitBtn.containsPoint(screenLocation) {
            } else {
                touchingLocation = touch
            }
        }
        
        self.updateSplitButtonPosition()
    }
    
    func updateSplitButtonPosition() {
        if let t = touchingLocation {
            let screenLocation = t.locationInNode(self)
            if screenLocation.x > frame.width * 0.7 {
                hudLayer.moveSplitButtonToLeft()
            }
            if screenLocation.x < frame.width * 0.3 {
                hudLayer.moveSplitButtonToRight()
            }
        }
    }
    
    override func touchesEnded(touches: Set<UITouch>, withEvent event: UIEvent?) {
        if touches.count <= 0 || paused {
            return
        }
        
        touchingLocation = nil
    }
}

//Contact Detection
extension GameScene : SKPhysicsContactDelegate {
    func didBeginContact(contact: SKPhysicsContact) {
        var fstBody : SKPhysicsBody
        var sndBody : SKPhysicsBody
        
        if contact.bodyA.categoryBitMask < contact.bodyB.categoryBitMask {
            fstBody = contact.bodyA
            sndBody = contact.bodyB
        } else {
            fstBody = contact.bodyB
            sndBody = contact.bodyA
        }
        
        if fstBody.categoryBitMask == GlobalConstants.Category.ball && sndBody.categoryBitMask == GlobalConstants.Category.virus {
            if let ball = fstBody.node as? Ball {
                if let virus = sndBody.node as? Virus {
                    if ball.radius >= virus.radius {
                        if let p = ball.parent {
                            ball.split(min(4, 16 - p.children.count + 1))
                            virus.removeFromParent()
                        }
                    }
                }
            }
            
        } else if fstBody.categoryBitMask == GlobalConstants.Category.food && sndBody.categoryBitMask == GlobalConstants.Category.ball {
            if let ball = sndBody.node as? Ball {
                ball.beginContact(fstBody.node as! Food)
            }
        } else if fstBody.categoryBitMask == GlobalConstants.Category.ball && sndBody.categoryBitMask == GlobalConstants.Category.ball {
            if var ball1 = fstBody.node as? Ball { // Big
                if var ball2 = sndBody.node as? Ball { // Small
                    if ball2.mass > ball1.mass {
                        let tmp = ball2
                        ball2 = ball1
                        ball1 = tmp
                    }
                    ball1.beginContact(ball2)
                }
            }
        }
    }
    
    func didEndContact(contact: SKPhysicsContact) {
        var fstBody : SKPhysicsBody
        var sndBody : SKPhysicsBody
        
        if contact.bodyA.categoryBitMask < contact.bodyB.categoryBitMask {
            fstBody = contact.bodyA
            sndBody = contact.bodyB
        } else {
            fstBody = contact.bodyB
            sndBody = contact.bodyA
        }
        if fstBody.categoryBitMask == GlobalConstants.Category.food && sndBody.categoryBitMask == GlobalConstants.Category.ball {
            if let ball = sndBody.node as? Ball {
                ball.endContact(fstBody.node as! Food)
            }
        } else if fstBody.categoryBitMask == GlobalConstants.Category.ball && sndBody.categoryBitMask == GlobalConstants.Category.ball {
            if var ball1 = fstBody.node as? Ball { // Big
                if var ball2 = sndBody.node as? Ball { // Small
                    if ball2.mass > ball1.mass {
                        let tmp = ball2
                        ball2 = ball1
                        ball1 = tmp
                    }
                    ball1.endContact(ball2)
                }
            }
        }
    }
}