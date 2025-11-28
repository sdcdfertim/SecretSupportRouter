// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Secret Support Ticket Router (Zama FHEVM)
 *
 * Goal:
 *  - Users submit encrypted ticket profile (4-dim vector + urgency).
 *  - Agents store encrypted skill vector (same 4 dims).
 *  - Contract computes encrypted scores per agent and selects an encrypted best match (argmax),
 *    keeping the routing decision secret onchain.
 *  - Only the user (msg.sender) and a designated RouterApp can decrypt the match.
 *
 * Principles / Constraints:
 *  - Uses only Zama official Solidity library & SepoliaConfig.
 *  - No FHE ops in view/pure; use FHE.allow / FHE.allowThis / FHE.allowTransient for ACL.
 *  - euint256/eaddress arithmetic is avoided.
 *  - Urgency is euint16 (no casting helpers are used/required).
 */

import {
    FHE,
    ebool,
    euint16,
    euint32,
    externalEuint16
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract SecretSupportRouter is ZamaEthereumConfig {
    /* ─────────────────────────── Admin / Ownership ─────────────────────────── */

    address public owner;
    address public routerApp; // off-chain app allowed to decrypt matches

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    /// @notice No-args constructor for universal deploy scripts.
    /// By default, routerApp = deployer; you can later call setRouterApp().
    constructor() {
        owner = msg.sender;
        routerApp = msg.sender;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        owner = newOwner;
    }

    function setRouterApp(address newRouterApp) external onlyOwner {
        require(newRouterApp != address(0), "Zero router");
        routerApp = newRouterApp;
    }

    function version() external pure returns (string memory) {
        return "SecretSupportRouter/1.0.1-noargs";
    }

    /* ─────────────────────────────── Parameters ────────────────────────────── */

    // Fixed dimensionality for skills/needs to keep homomorphic loops predictable.
    uint8 public constant DIM = 4;

    // Hard cap on active agents iterated during routing to bound FHE gas.
    uint16 public constant MAX_AGENTS = 2000;

    /* ───────────────────────────── Agent Registry ──────────────────────────── */

    struct Agent {
        bool active;
        // Encrypted skill vector per dimension (euint16 each).
        euint16[DIM] skill;
    }

    // agentId => Agent
    mapping(uint32 => Agent) private _agents;
    // Active ids list; we keep holes on deactivation and check the flag during iteration.
    uint32[] private _activeAgentIds;

    event AgentUpserted(uint32 indexed agentId, bool active);
    event AgentRemoved(uint32 indexed agentId);

    /// @notice Owner registers/updates agent's encrypted skills (all inputs share the same proof).
    function upsertAgentEncrypted(
        uint32 agentId,
        externalEuint16[DIM] calldata skillExt,
        bytes calldata proof,
        bool active
    ) external onlyOwner {
        require(agentId != 0, "Bad agentId");
        Agent storage a = _agents[agentId];

        // Deserialize & store skills
        for (uint8 i = 0; i < DIM; i++) {
            euint16 s = FHE.fromExternal(skillExt[i], proof);
            a.skill[i] = s;
            // Allow the contract to reuse the ciphertext across txs
            FHE.allowThis(s);
        }

        if (active && !a.active) {
            require(_activeAgentIds.length < MAX_AGENTS, "Agents cap");
            _activeAgentIds.push(agentId);
        }
        a.active = active;

        emit AgentUpserted(agentId, active);
    }

    /// @notice DEV ONLY: set plain skills (for demos/tests). Do not use in production.
    function upsertAgentPlain(
        uint32 agentId,
        uint16[DIM] calldata skillPlain,
        bool active
    ) external onlyOwner {
        require(agentId != 0, "Bad agentId");
        Agent storage a = _agents[agentId];

        for (uint8 i = 0; i < DIM; i++) {
            a.skill[i] = FHE.asEuint16(skillPlain[i]);
            FHE.allowThis(a.skill[i]);
        }

        if (active && !a.active) {
            require(_activeAgentIds.length < MAX_AGENTS, "Agents cap");
            _activeAgentIds.push(agentId);
        }
        a.active = active;

        emit AgentUpserted(agentId, active);
    }

    /// @notice Deactivate agent; encrypted values remain but are not used.
    function removeAgent(uint32 agentId) external onlyOwner {
        Agent storage a = _agents[agentId];
        require(a.active, "Not active");
        a.active = false;
        emit AgentRemoved(agentId);
    }

    function activeAgentCount() external view returns (uint256) {
        return _activeAgentIds.length;
    }

    /* ───────────────────────────── Tickets & Routing ───────────────────────── */

    struct TicketMatch {
        bool exists;
        euint32 agentIdCt; // encrypted best agentId
    }

    // ticketId => encrypted match
    mapping(bytes32 => TicketMatch) private _matches;

    event TicketSubmitted(
        bytes32 indexed ticketId,
        address indexed user,
        bytes32 agentIdHandle // euint32 handle for UI decryption
    );

    /**
     * @notice Submit encrypted ticket profile and compute a secret best match.
     * @param ticketId arbitrary unique id chosen by frontend (e.g., keccak of client-side salt)
     * @param needExt  encrypted vector length DIM (need per category, uint16)
     * @param urgencyExt encrypted uint16 (0..65535), bounded bonus weight
     * @param proof  relayer attestation for all external values (same batch)
     * @return bestAgentIdCt encrypted agent id (euint32)
     *
     * Decryption rights:
     *  - msg.sender (user) and routerApp can decrypt the resulting agentId.
     *  - No grants to the agent address to keep routing fully private on-chain.
     */
    function submitTicketAndRoute(
        bytes32 ticketId,
        externalEuint16[DIM] calldata needExt,
        externalEuint16 urgencyExt,
        bytes calldata proof
    ) external returns (euint32 bestAgentIdCt) {
        require(!_matches[ticketId].exists, "Ticket exists");
        require(_activeAgentIds.length > 0, "No agents");

        // Deserialize inputs
        euint16[DIM] memory need;
        for (uint8 i = 0; i < DIM; i++) {
            need[i] = FHE.fromExternal(needExt[i], proof);
        }
        euint16 urgency = FHE.fromExternal(urgencyExt, proof);

        // Running best=(score,id).
        euint16 bestScore = FHE.asEuint16(0);
        euint32 bestId    = FHE.asEuint32(0);

        // Iterate through active agents; compute encrypted score and argmax
        uint256 n = _activeAgentIds.length;
        for (uint256 idx = 0; idx < n; idx++) {
            uint32 agentId = _activeAgentIds[idx];
            Agent storage a = _agents[agentId];
            if (!a.active) continue; // skip inactive holes

            // score_i = sum_k min(need[k], skill[k])  (simple overlap metric)
            euint16 score = FHE.asEuint16(0);
            for (uint8 k = 0; k < DIM; k++) {
                euint16 mk = FHE.min(need[k], a.skill[k]);
                score = FHE.add(score, mk);
            }

            // Bounded urgency boost to keep scale modest: score += min(score, urgency)
            euint16 bonus = FHE.min(score, urgency);
            score = FHE.add(score, bonus);

            // If score > bestScore then update (bestScore,bestId)
            ebool better = FHE.gt(score, bestScore);
            bestScore = FHE.select(better, score, bestScore);
            euint32 encId = FHE.asEuint32(agentId);
            bestId   = FHE.select(better, encId, bestId);
        }

        // Persist encrypted result
        TicketMatch storage tm = _matches[ticketId];
        tm.exists = true;
        tm.agentIdCt = bestId;

        // ACL: allow contract reuse and private decrypt for user and RouterApp
        FHE.allowThis(bestId);
        FHE.allow(bestId, msg.sender);
        FHE.allow(bestId, routerApp);

        emit TicketSubmitted(ticketId, msg.sender, FHE.toBytes32(bestId));
        return bestId;
    }

    /* ─────────────────────────────── Read helpers ───────────────────────────── */

    /// @notice Returns encrypted handle for the matched agent id (if computed).
    function getMatchHandle(bytes32 ticketId) external view returns (bytes32) {
        TicketMatch storage tm = _matches[ticketId];
        if (!tm.exists) return bytes32(0);
        return FHE.toBytes32(tm.agentIdCt);
    }

    /// @notice DEV ONLY: mark this ticket's encrypted agentId as publicly decryptable (demo).
    function makeMatchPublic(bytes32 ticketId) external onlyOwner {
        TicketMatch storage tm = _matches[ticketId];
        require(tm.exists, "No match");
        FHE.makePubliclyDecryptable(tm.agentIdCt);
    }

    /* ───────────────────────────── DEV utilities ────────────────────────────── */

    /// @notice Plain submit for local testing (DO NOT USE IN PROD).
    function submitTicketPlain(
        bytes32 ticketId,
        uint16[DIM] calldata needPlain,
        uint16 urgencyPlain
    ) external returns (euint32 bestAgentIdCt) {
        require(!_matches[ticketId].exists, "Ticket exists");
        require(_activeAgentIds.length > 0, "No agents");

        // Mirror encrypted logic with asEuint
        euint16[DIM] memory need;
        for (uint8 i = 0; i < DIM; i++) {
            need[i] = FHE.asEuint16(needPlain[i]);
        }
        euint16 urgency = FHE.asEuint16(urgencyPlain);

        euint16 bestScore = FHE.asEuint16(0);
        euint32 bestId    = FHE.asEuint32(0);

        uint256 n = _activeAgentIds.length;
        for (uint256 idx = 0; idx < n; idx++) {
            uint32 agentId = _activeAgentIds[idx];
            Agent storage a = _agents[agentId];
            if (!a.active) continue;

            euint16 score = FHE.asEuint16(0);
            for (uint8 k = 0; k < DIM; k++) {
                euint16 mk = FHE.min(need[k], a.skill[k]);
                score = FHE.add(score, mk);
            }
            euint16 bonus = FHE.min(score, urgency);
            score = FHE.add(score, bonus);

            ebool better = FHE.gt(score, bestScore);
            bestScore = FHE.select(better, score, bestScore);
            euint32 encId = FHE.asEuint32(agentId);
            bestId   = FHE.select(better, encId, bestId);
        }

        TicketMatch storage tm = _matches[ticketId];
        tm.exists = true;
        tm.agentIdCt = bestId;

        FHE.allowThis(bestId);
        FHE.allow(bestId, msg.sender);
        FHE.allow(bestId, routerApp);

        emit TicketSubmitted(ticketId, msg.sender, FHE.toBytes32(bestId));
        return bestId;
    }
}
