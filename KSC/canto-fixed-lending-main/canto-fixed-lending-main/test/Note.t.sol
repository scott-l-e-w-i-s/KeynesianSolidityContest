// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import { Note } from "../src/Note.sol";

contract NoteTest is Test {
    function testNoteMint() public {
        Note note = new Note("Note", "NOTE");

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        uint256 id1 = note.mint(user1);
        uint256 id2 = note.mint(user2);

        assertGt(id2, id1);
        assertEq(note.ownerOf(id1), user1);
        assertEq(note.ownerOf(id2), user2);
    }
}
