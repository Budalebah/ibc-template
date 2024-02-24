pragma solidity ^0.8.24;

import "./IIBCModule.sol";
import "./IIBCPacketHandler.sol";

// Protocol specific packet
struct PingPongPacket {
    bool ping;
    uint64 counterpartyTimeout;
}

library PingPongLib {
    bytes1 public constant ACK_SUCCESS = 0x01;

    error ErrNotIBC();
    error ErrOnlyOneChannel();
    error ErrInvalidAck();
    error ErrNoChannel();
    error ErrInfiniteGame();

    event Ring(bool ping);
    event TimedOut();
    event Acknowledged();

    function encode(
        PingPongPacket memory packet
    ) internal pure returns (bytes memory) {
        return abi.encode(packet.ping, packet.counterpartyTimeout);
    }

    function decode(
        bytes memory packet
    ) internal pure returns (PingPongPacket memory) {
        (bool ping, uint64 counterpartyTimeout) = abi.decode(
            packet,
            (bool, uint64)
        );
        return
            PingPongPacket({
                ping: ping,
                counterpartyTimeout: counterpartyTimeout
            });
    }
}

contract PingPong is IIBCModule {
    using PingPongLib for *;

    IIBCPacketHandler private ibcHandler;
    string private portId;
    string private channelId;
    uint64 private revisionNumber;
    uint64 private timeout;

    constructor(
        IIBCPacketHandler _ibcHandler,
        uint64 _revisionNumber,
        uint64 _timeout
    ) {
        ibcHandler = _ibcHandler;
        revisionNumber = _revisionNumber;
        timeout = _timeout;
    }

    function initiate(
        PingPongPacket memory packet,
        uint64 localTimeout
    ) public {
        if (bytes(channelId).length == 0) {
            revert PingPongLib.ErrNoChannel();
        }
        ibcHandler.sendPacket(
            portId,
            channelId,
            // No height timeout
            IbcCoreClientV1Height.Data({
                revision_number: 0,
                revision_height: 0
            }),
            // Timestamp timeout
            localTimeout,
            // Raw protocol packet
            packet.encode()
        );
    }

    function onRecvPacket(
        IbcCoreChannelV1Packet.Data calldata packet,
        address relayer
    ) external virtual override onlyIBC returns (bytes memory acknowledgement) {
        PingPongPacket memory pp = PingPongLib.decode(packet.data);

        emit PingPongLib.Ring(pp.ping);

        uint64 localTimeout = pp.counterpartyTimeout;

        pp.ping = !pp.ping;
        pp.counterpartyTimeout = uint64(block.timestamp) + timeout;

        // Send back the packet after having reversed the bool and set the counterparty timeout
        initiate(pp, localTimeout);

        // Return protocol specific successful acknowledgement
        return abi.encodePacked(PingPongLib.ACK_SUCCESS);
    }

    function onAcknowledgementPacket(
        IbcCoreChannelV1Packet.Data calldata packet,
        bytes calldata acknowledgement,
        address relayer
    ) external virtual override onlyIBC {
        /*
            In practice, a more sophisticated protocol would check
            and execute code depending on the counterparty outcome (refund etc...).
            In our case, the acknowledgement will always be ACK_SUCCESS
        */
        if (
            keccak256(acknowledgement) !=
            keccak256(abi.encodePacked(PingPongLib.ACK_SUCCESS))
        ) {
            revert PingPongLib.ErrInvalidAck();
        }
        emit PingPongLib.Acknowledged();
    }

    function onTimeoutPacket(
        IbcCoreChannelV1Packet.Data calldata packet,
        address relayer
    ) external virtual override onlyIBC {
        /*
            Similarly to the onAcknowledgementPacket function, this indicates a failure to deliver the packet in expected time.
            A sophisticated protocol would revert the action done before sending this packet.
        */
        emit PingPongLib.TimedOut();
    }

    function onChanOpenInit(
        IbcCoreChannelV1GlobalEnums.Order,
        string[] calldata,
        string calldata,
        string calldata,
        IbcCoreChannelV1Counterparty.Data calldata,
        string calldata
    ) external virtual override onlyIBC {
        // This protocol is only accepting a single counterparty.
        if (bytes(channelId).length != 0) {
            revert PingPongLib.ErrOnlyOneChannel();
        }
    }

    function onChanOpenTry(
        IbcCoreChannelV1GlobalEnums.Order,
        string[] calldata,
        string calldata,
        string calldata,
        IbcCoreChannelV1Counterparty.Data calldata,
        string calldata,
        string calldata
    ) external virtual override onlyIBC {
        // Symmetric to onChanOpenInit
        if (bytes(channelId).length != 0) {
            revert PingPongLib.ErrOnlyOneChannel();
        }
    }

    function onChanOpenAck(
        string calldata _portId,
        string calldata _channelId,
        string calldata _counterpartyChannelId,
        string calldata _counterpartyVersion
    ) external virtual override onlyIBC {
        // Store the port/channel needed to send packets.
        portId = _portId;
        channelId = _channelId;
    }

    function onChanOpenConfirm(
        string calldata _portId,
        string calldata _channelId
    ) external virtual override onlyIBC {
        // Symmetric to onChanOpenAck
        portId = _portId;
        channelId = _channelId;
    }

    function onChanCloseInit(
        string calldata _portId,
        string calldata _channelId
    ) external virtual override onlyIBC {
        // The ping-pong is infinite, closing the channel is disallowed.
        revert PingPongLib.ErrInfiniteGame();
    }

    function onChanCloseConfirm(
        string calldata _portId,
        string calldata _channelId
    ) external virtual override onlyIBC {
        // Symmetric to onChanCloseInit
        revert PingPongLib.ErrInfiniteGame();
    }

    /**
     * @dev Throws if called by any account other than the IBC contract.
     */
    modifier onlyIBC() {
        _checkIBC();
        _;
    }

    /**
     * @dev Throws if the sender is not the IBC contract.
     */
    function _checkIBC() internal view virtual {
        if (_ibcHandler != _msgSender()) {
            revert PingPongLib.ErrNotIBC();
        }
    }
}
