//
//  RemoteAssetRegistry+Parts.swift
//  NeuraLink
//
//  The customization parts library, as a manifest rather than as bundled
//  files. The 68 cut-out donor parts weigh 225 MB, which is more than the
//  rest of the app put together, and nothing at startup needs them — so
//  they live in the Hugging Face dataset next to the environment GLBs and
//  come down on first launch. Sizes and hashes were captured from the
//  dataset tree API; re-uploading a part REQUIRES updating its entry here,
//  or the download is rejected as tampered.
//

import Foundation

extension RemoteAssetRegistry {

    /// Every part file in the library, as its stem. The picker builds
    /// itself from this list, so a part that is not here does not exist.
    static let libraryPartStems: [String] = [
        "boy_uniform__bottoms", "boy_uniform__hair",
        "boy_uniform__outfit", "boy_uniform__shoes",
        "boy_uniform__tops", "brownie__eyes",
        "brownie__hair", "brownie__outfit",
        "bunny_girl__eyes", "bunny_girl__hair",
        "bunny_girl__outfit", "bunny_girl__shoes",
        "casual__bottoms", "casual__eyes",
        "casual__hair", "casual__outfit",
        "casual__shoes", "casual__tops",
        "classic__eyes", "classic__hair",
        "classic__outfit", "classic__shoes",
        "classic__tops", "classic_bunny_girl__eyes",
        "classic_bunny_girl__hair", "classic_bunny_girl__outfit",
        "classic_bunny_girl__shoes", "cool__eyes",
        "cool__hair", "cool__outfit",
        "cyberpunk__eyes", "cyberpunk__hair",
        "cyberpunk__outfit", "cyberpunk__shoes",
        "cyberpunk__tops", "dress__eyes",
        "dress__hair", "dress__outfit",
        "dress__shoes", "dress__tops",
        "goth__eyes", "goth__hair",
        "goth__outfit", "goth__shoes",
        "goth__tops", "maid__eyes",
        "maid__hair", "maid__outfit",
        "maid__shoes", "maid__tops",
        "school_uniform_2__bottoms", "school_uniform_2__eyes",
        "school_uniform_2__hair", "school_uniform_2__outfit",
        "school_uniform_2__shoes", "school_uniform_2__tops",
        "school_uniform_3__bottoms", "school_uniform_3__eyes",
        "school_uniform_3__hair", "school_uniform_3__outfit",
        "school_uniform_3__shoes", "school_uniform_3__tops",
        "school_uniform__bottoms", "school_uniform__eyes",
        "school_uniform__hair", "school_uniform__outfit",
        "school_uniform__shoes", "school_uniform__tops"
    ]

    /// Total download for the whole library, used for progress before
    /// any individual file has reported its size.
    static let libraryPartsTotalBytes: Int64 = 226503624

    /// Keyed by part stem. Captured from the dataset tree API 2026-09-27.
    static let libraryPartIntegrity: [String: AssetIntegrity] = [
        "boy_uniform__bottoms": .init(
            size: 925_432,
            sha256: "985b1e0803208d4adb03868db45565a68656f557bd3d9fc980d90be239aef28b"),
        "boy_uniform__hair": .init(
            size: 2_591_888,
            sha256: "55c00c7c6adda420e3322f0ef0ef51f8cbc213cabd9ec7d64bdaaa524303d64b"),
        "boy_uniform__outfit": .init(
            size: 7_923_340,
            sha256: "dcb3fd74c0cc0f21712d1e55b4d00c1ae3be07b0b6e0f8bdec0839761adddab4"),
        "boy_uniform__shoes": .init(
            size: 1_031_036,
            sha256: "6eadd3410b271abca53d8deed7d4e888fa57a0c007cb126e25e8da36a03edf8d"),
        "boy_uniform__tops": .init(
            size: 2_574_080,
            sha256: "1485848d4eb2a0897548215459f786f51fa09560e1a97c4bbc3e1107ac5127ab"),
        "brownie__eyes": .init(
            size: 6_568_464,
            sha256: "cdaef622e10e5f0eeba014223a06933339c97d4a4714590d82177e1daaf4b820"),
        "brownie__hair": .init(
            size: 12_721_092,
            sha256: "722232eed0d16da6f94752c8867f85927cf11ffb115b8601a0c081a41e01bba6"),
        "brownie__outfit": .init(
            size: 12_696_848,
            sha256: "cf0f874e3549d7dd35314cd62714a981660cce5dfe342107c31f0639d5170451"),
        "bunny_girl__eyes": .init(
            size: 496_880,
            sha256: "c140a598e746da1cd1d217c3885ee4b148f769edcaaa4d4939326f6ece14a24a"),
        "bunny_girl__hair": .init(
            size: 2_192_444,
            sha256: "64ebaa74f2417be1bf2e9ceeccbf0baa7daf6404fb66f561b7094498f94c7d68"),
        "bunny_girl__outfit": .init(
            size: 9_287_156,
            sha256: "69c9ee5b8aecae172e1af2498180facfe63ea21f72176c0802e94f069dc2a603"),
        "bunny_girl__shoes": .init(
            size: 733_180,
            sha256: "2bfdc974ad21b94a59ed15a87fe596d0fc5914efffa819392d66360c1b803566"),
        "casual__bottoms": .init(
            size: 451_360,
            sha256: "0bad78c56327844294613cf638927b727117dfff89b92048fd1a10153f6943d7"),
        "casual__eyes": .init(
            size: 756_280,
            sha256: "4ba70df9bcc7ca29340b41421f7e96157d3beefcba2f4c4d6f243c3bbed3b902"),
        "casual__hair": .init(
            size: 2_498_744,
            sha256: "7251fb0ae4ae6a7d1bd319d6790d61bc8aa5c33d60fd3a3d147174bdcfacf714"),
        "casual__outfit": .init(
            size: 6_700_848,
            sha256: "3ef1eb7106b6ca4cf921c1b7dc23cba3c359120559785c9934f2e9f20408dfa0"),
        "casual__shoes": .init(
            size: 277_504,
            sha256: "7a83e264a682e73a105273bf78cdb205704d24bba2e17187563a96afa89d1c89"),
        "casual__tops": .init(
            size: 717_788,
            sha256: "a03ce11a84f9f165330c4275138884f65bdbe96a276cd685548c20bd50ffd13c"),
        "classic__eyes": .init(
            size: 668_864,
            sha256: "c326009eda319f9823b7cbeba8c9081b580a08c820a8115bdab6c62194776fb1"),
        "classic__hair": .init(
            size: 2_353_252,
            sha256: "3254cbbea7ec864017395a539bbe42473a54c110f2cfcb6a7145b44e21392cc9"),
        "classic__outfit": .init(
            size: 8_890_924,
            sha256: "006c73f1745e85cfafc555f10ef4eddc5f3836de733929864dcf4a725ca87b1a"),
        "classic__shoes": .init(
            size: 296_688,
            sha256: "7a71851e060a022dea78aa8a566ddf6519a7a29ad0fbc8d4358a252cc85be5c5"),
        "classic__tops": .init(
            size: 2_842_928,
            sha256: "a65585d909580e172402f0a692b3f4e2712c97b95685df7050b0aa39079b1829"),
        "classic_bunny_girl__eyes": .init(
            size: 605_036,
            sha256: "e358b784a43d4eb9846c65a24a3ffa7fb2774d610415477ec1fdd5f811ca0fec"),
        "classic_bunny_girl__hair": .init(
            size: 1_983_580,
            sha256: "47b9c64769f9610ab5d0af1e0829d9b7784ac4478c6cfb40a5f3560200acd749"),
        "classic_bunny_girl__outfit": .init(
            size: 6_966_628,
            sha256: "a284e881350fd8d7ac12dc930b50f3b33cc17be5529b32a6f3b01a6926841b79"),
        "classic_bunny_girl__shoes": .init(
            size: 599_820,
            sha256: "4ffcd8d4929733e6bb876813dca2d6d8e407ba06800e54560f988f344281405a"),
        "cool__eyes": .init(
            size: 6_163_832,
            sha256: "10bc7b807b202804d4784e3d56cff91d86236c238216bb7d95a4f2073771d0cf"),
        "cool__hair": .init(
            size: 12_322_800,
            sha256: "75d9f2e1604c4c09118ebef954cedf76106b2df3971bc08b4c35d132af9c166e"),
        "cool__outfit": .init(
            size: 12_341_732,
            sha256: "b55cb5a62830d259bb6d291171948c2ed4c77970c701fab45d8426cbbfb68f54"),
        "cyberpunk__eyes": .init(
            size: 571_068,
            sha256: "72dd2253eb217c1921769692516420c2650b73726cab802f5741a130c1377188"),
        "cyberpunk__hair": .init(
            size: 2_086_160,
            sha256: "7b0dab68e3434545d2cd6d1ba7afbc7c9f5527307d028d3cf45416375f686e13"),
        "cyberpunk__outfit": .init(
            size: 6_234_552,
            sha256: "4545185ef40e5b7a8b92274f4de2f33149f86be5637c86ee622ca233251a30dd"),
        "cyberpunk__shoes": .init(
            size: 311_896,
            sha256: "3abbcc882230a5d72e2f52679c4db737eed4ccfaa1cdc884591defab3a63a3f1"),
        "cyberpunk__tops": .init(
            size: 1_376_856,
            sha256: "a93b39c0a12d8521ebe6edbebcca2065babd1bfdcec19873ddf0346d0eaaf125"),
        "dress__eyes": .init(
            size: 665_144,
            sha256: "ed4caf9dd2c858c00a9e0a80edf5684a4be476d66abfab4d842e87b929a38643"),
        "dress__hair": .init(
            size: 2_079_876,
            sha256: "a1dceefc94f50a1236c8ae3d3c2dddf25df46562d50edb698e8eea467a17f83b"),
        "dress__outfit": .init(
            size: 7_356_408,
            sha256: "2e3890a4cd2fba48528fdf63c40f708d961e0f287cf3b1ea743ad32d29bda7e4"),
        "dress__shoes": .init(
            size: 286_456,
            sha256: "94169175dac5d33a9008f0a8d1c134e1e2ad6248bc815ffa02243e84072a7b26"),
        "dress__tops": .init(
            size: 2_647_568,
            sha256: "b37f84013aa621089078fd05787bff44a08bf66467b1b4d6975c7107720d2e96"),
        "goth__eyes": .init(
            size: 888_264,
            sha256: "5c7bf15f0616ea5d8e9fd46d63ae035dacf54589aa93c8ba01fab1d8e15cc638"),
        "goth__hair": .init(
            size: 2_965_892,
            sha256: "fbab4afe204af95c5913cbeaa6e44b288b1f85f7f5361a094ee180deb85735f2"),
        "goth__outfit": .init(
            size: 9_997_544,
            sha256: "5953f4b6e480993faa29be6bc39410e112e7eadaa0195ebaefb106a49e893c77"),
        "goth__shoes": .init(
            size: 310_504,
            sha256: "9a4c6ac2992b75e9686f824b6538324e658f987766a61f57e2675b5b6b2db5f1"),
        "goth__tops": .init(
            size: 5_060_820,
            sha256: "94d199145755ab1a66788ace50e3b0501a9243f01fb4e7cf5c8aa0182893ccff"),
        "maid__eyes": .init(
            size: 589_880,
            sha256: "8a88676fe4ce75523d1f5d0c3783a78a496a5f816440877a5f791aef8dc50abf"),
        "maid__hair": .init(
            size: 1_163_276,
            sha256: "3a3968188079b87dde516bb6930f5c04326043d4bc2cd4816f88cf4f33fc3d07"),
        "maid__outfit": .init(
            size: 6_353_920,
            sha256: "1ff8994ba3eadc1a59413322e1d4d66500ad8be9f6eae0d1c116723ec5e5918f"),
        "maid__shoes": .init(
            size: 213_560,
            sha256: "989715f3864074b4f80164906b4b1dcb67af30cd699626893fe459d298ec253a"),
        "maid__tops": .init(
            size: 1_137_412,
            sha256: "6357d8efc4f44466e69825aaaaffeaa35ad0427263942850fd71e51d868728ca"),
        "school_uniform_2__bottoms": .init(
            size: 729_792,
            sha256: "794fbbfd34b75eb01e7c89d335d81c58953a367a3cbdd2ad8e14ca43228ef4d2"),
        "school_uniform_2__eyes": .init(
            size: 683_364,
            sha256: "2fbe5d5ebb1de25619a282612c41b4ecc8bc0da546f1ba6b367d37c1ca396eb4"),
        "school_uniform_2__hair": .init(
            size: 2_278_624,
            sha256: "d57ebf8c443836f67865e9b442ae45dc4054fba039a086a7c885691a9d2ceca1"),
        "school_uniform_2__outfit": .init(
            size: 9_878_276,
            sha256: "3bba2796911149cd70a2b4ea2f44379abd7b678d8695e8704cc30685f4346e11"),
        "school_uniform_2__shoes": .init(
            size: 238_272,
            sha256: "d581f8c0323bb702e65fd001502f23b452cca7e47f3c9f1956516dfe83aa0064"),
        "school_uniform_2__tops": .init(
            size: 3_977_580,
            sha256: "bebf6f5e77056718ecc5186668a1ffe28f8c68c555fa6cd38325ea2c166b96dd"),
        "school_uniform_3__bottoms": .init(
            size: 319_952,
            sha256: "59ff416f09348cb902a44b8a1eb49e4193728bc6162d80ba4a6e65c140924d27"),
        "school_uniform_3__eyes": .init(
            size: 605_764,
            sha256: "43455a4d720b267fbc7f2cd33e6a03003d1219054dc596041ef425e3c5ee7ef2"),
        "school_uniform_3__hair": .init(
            size: 2_245_652,
            sha256: "de354ce9ae33bdda07495de3c58c95348d4063b29c724d71978280f566f45908"),
        "school_uniform_3__outfit": .init(
            size: 6_414_240,
            sha256: "6dae5023b5c0cf538a34195a39d6031524cc9af2eaf9d28b641aa95deb5de497"),
        "school_uniform_3__shoes": .init(
            size: 242_988,
            sha256: "5a5fb672dcfb47c113d693fb8db401e204240d99d23b849429d69934c7243c3f"),
        "school_uniform_3__tops": .init(
            size: 1_740_420,
            sha256: "ff2c61e0f4b43183e632a598b862550941e4e14012aaa7db2476d4e22e118df5"),
        "school_uniform__bottoms": .init(
            size: 733_008,
            sha256: "c19d6643329d6fe0fc30c7f3b5a1891f458367e2a2ac0f14a84643ff0d7dfdce"),
        "school_uniform__eyes": .init(
            size: 662_208,
            sha256: "b6b1b599793dc0e5d8668c4bdb1f79f15afee5f9d7ba0dbcdaa6f882207ba37b"),
        "school_uniform__hair": .init(
            size: 2_075_980,
            sha256: "2987990796831669d38a92855c42e029bb0caa91773b865a2576c30be2ee9cf7"),
        "school_uniform__outfit": .init(
            size: 9_977_724,
            sha256: "03888b66e1bda01ae62018ec173bf5da0e2c8f3dcd611ebbc9d7cea24e718ada"),
        "school_uniform__shoes": .init(
            size: 241_488,
            sha256: "5502e4053ed0b0dfa54e2b914616b08d4f81bc7d194eef0aa27d970b153a9fa9"),
        "school_uniform__tops": .init(
            size: 3_980_788,
            sha256: "195590fa129192d4764eeddd308334d5c1e93ba677006787dfaec06e778acfc0")
    ]
}
