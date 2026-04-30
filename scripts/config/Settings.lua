-- ============================================================================
-- Settings.lua - Game Configuration (Ball Collision Multiplayer)
-- ============================================================================

local Settings = {}

-- ============================================================================
-- Arena & Display
-- ============================================================================

Settings.Arena = {
    Size            = 400,       -- arena square side length (logical pixels)
    DesignWidth     = 1920,
    DesignHeight    = 1080,
}

-- ============================================================================
-- Ball
-- ============================================================================

Settings.Ball = {
    Radius          = 20,
    Speed           = 150,
    InitialSpeed    = 120,       -- initial launch speed (pixels/s)
    SpeedCap        = 300,       -- max speed cap (pixels/s)
    BounceRestitution = 0.95,    -- wall bounce energy retention
    CollisionDamage = 2,
    MaxHP           = 100,
}

-- ============================================================================
-- HP Tiers (skill activation ranges)
-- ============================================================================

Settings.Tiers = {
    normal   = { min = 50, max = 100 },  -- 普通技能 HP 100-50
    enhanced = { min = 20, max = 50  },  -- 强化技能 HP 50-20
    ultimate = { min = 0,  max = 20  },  -- 决战技能 HP 20-0
}

-- ============================================================================
-- Blue Ball - Water Jet (Normal, HP >= 50)
-- ============================================================================

Settings.Water = {
    Speed       = 700,
    Radius      = 8,
    Damage      = 5,
    Knockback   = 280,
    Cooldown    = 5,
    TrailLen    = 6,
}

-- ============================================================================
-- Blue Ball - Wall Splash
-- ============================================================================

Settings.Splash = {
    Count       = 8,
    Speed       = 250,
    Radius      = 4,
    Damage      = 2,
    SpreadAngle = math.pi,
    TrailLen    = 3,
}

-- ============================================================================
-- Blue Ball - Rage Water Beam (HP < 50)
-- ============================================================================

Settings.RageWater = {
    Speed           = 1000,
    BeamWidth       = 10,
    Damage          = 10,
    Knockback       = 600,
    Cooldown        = 5,
    Length           = 50,
    WallSlamDmg     = 10,
    KnockbackWindow = 0.8,
}

-- ============================================================================
-- Red Ball - Homing Bullets
-- ============================================================================

Settings.Homing = {
    Speed       = 340,
    Radius      = 6,
    Count       = 4,
    TurnRate    = 1.8,
    DotTotal    = 3,
    DotDuration = 3,
    HealTotal   = 3,
    Cooldown    = 10,
    SpreadAngle = 0.55,
}

-- ============================================================================
-- Damage Popup
-- ============================================================================

Settings.Popup = {
    Duration        = 0.9,
    RiseSpeed       = 60,
    BaseFontSize    = 20,
    FontSizePerDmg  = 4,
    MaxFontSize     = 64,
    BaseShake       = 1,
    ShakePerDmg     = 1.2,
    MaxShake        = 20,
    ShakeFreq       = 30,
    ScalePunchTime  = 0.15,
    ScalePunchAmount = 1.5,
}

-- ============================================================================
-- AI Configuration
-- ============================================================================

Settings.AI = {
    PreferredDistance = 180,   -- ideal distance from opponent
    DodgeRadius      = 60,    -- dodge projectiles within this radius
    AimLeadFactor    = 0.3,   -- lead prediction multiplier
    ShootRandomDelay = 0.3,   -- random additional delay on auto-shoot
}

-- ============================================================================
-- Network
-- ============================================================================

Settings.Network = {
    MaxPlayers = 2,
}

-- ============================================================================
-- Control Bit Flags (sent via connection.controls.buttons)
-- ============================================================================

Settings.CTRL = {
    MOVE_UP      = 1,
    MOVE_DOWN    = 2,
    MOVE_LEFT    = 4,
    MOVE_RIGHT   = 8,
    SHOOT        = 16,
    ABILITY      = 32,
    CANCEL_PROXY = 64,
}

-- ============================================================================
-- Remote Events
-- ============================================================================

Settings.EVENTS = {
    CLIENT_READY    = "BallClientReady",
    ASSIGN_ROLE     = "BallAssignRole",
    HEALTH_UPDATE   = "BallHealthUpdate",
    BALL_DIED       = "BallDied",
    BALL_RESPAWN    = "BallRespawn",
    ABILITY_FIRED   = "BallAbilityFired",
    ANNOUNCEMENT    = "BallAnnouncement",
    DAMAGE_POPUP    = "BallDamagePopup",
    PROJECTILE_SYNC = "BallProjectileSync",
    GAME_STATE      = "BallGameState",
    GAME_START      = "BallGameStart",
}

-- ============================================================================
-- Node Variables (synced via REPLICATED nodes)
-- ============================================================================

Settings.VARS = {
    IS_BALL     = "IsBall",
    BALL_TEAM   = "BallTeam",     -- 1=blue, 2=red
    BALL_HP     = "BallHP",
    BALL_MAX_HP = "BallMaxHP",
    BALL_VX     = "BallVX",       -- velocity x (for client interpolation)
    BALL_VY     = "BallVY",       -- velocity y
    IS_RAGE     = "IsRage",       -- rage mode flag
    IS_PROXY    = "IsProxy",      -- AI controlling this ball
}

-- ============================================================================
-- Spawn Points (2D, will be mapped to Vector3(x, 0, y))
-- ============================================================================

Settings.SpawnPoints = {
    { x = -100, y = 0 },   -- Ball 1 (blue, left)
    { x = 100,  y = 0 },   -- Ball 2 (red, right)
}

return Settings
