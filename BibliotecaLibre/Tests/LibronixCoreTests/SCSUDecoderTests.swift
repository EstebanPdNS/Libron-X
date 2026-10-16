import Foundation
import Testing
@testable import LibronixCore
struct SCSUDecoderTests {
    @Test func everyWindowAndBothModeCommandFamiliesFollowTheUnicodeSpecification() throws {
        let fixed = [0,0x80,0x100,0x300,0x2000,0x2080,0x2100,0x3000]
        let dynamic = [0x80,0xc0,0x400,0x600,0x900,0x3040,0x30a0,0xff00]
        func character(_ scalar: Int) -> String { String(Unicode.Scalar(scalar)!) }
        for n in 0..<8 {
            #expect(try SCSUDecoder.decode(Data([UInt8(n+1),0x21])) == character(fixed[n]+0x21))
            #expect(try SCSUDecoder.decode(Data([UInt8(n+1),0x80])) == character(dynamic[n]))
            #expect(try SCSUDecoder.decode(Data([UInt8(0x10+n),0x80])) == character(dynamic[n]))
            #expect(try SCSUDecoder.decode(Data([UInt8(0x18+n),0xfb,0x81])) == character(0x371))
            #expect(try SCSUDecoder.decode(Data([0x0f,UInt8(0xe0+n),0x80])) == character(dynamic[n]))
            #expect(try SCSUDecoder.decode(Data([0x0f,UInt8(0xe8+n),0xff,0x80])) == character(0xff60))
        }
        #expect(try SCSUDecoder.decode(Data([0x0f,0xf0,0xe1,0x23])) == character(0xe123))
        #expect(try SCSUDecoder.decode(Data([0x0b,0,0,0x80])) == character(0x10000))
        #expect(try SCSUDecoder.decode(Data([0x0f,0xf1,0xe0,1,0xff])) == character(0x100ff))
        #expect(try SCSUDecoder.decode(Data([0x0e,0xd8,0x3e,0x0e,0xdd,0x89])) == "🦉")
    }
    @Test func independentICUEncodedMultiscriptAndSupplementaryVectors() throws {
        struct Vector: Decodable { let text: String; let hex: String }
        let json = #"""
[
  {
    "text": "",
    "hex": ""
  },
  {
    "text": "Creación, Amón y Jerusalén",
    "hex": "437265616369f36e2c20416df36e2079204a65727573616ce96e"
  },
  {
    "text": "English and português français",
    "hex": "456e676c69736820616e6420706f7274756775ea73206672616ee7616973"
  },
  {
    "text": "Ελληνικά Ἀρχή",
    "hex": "1ffba5cbcbc7cdc9cabc20183e8817d1d7be"
  },
  {
    "text": "עברית שָׁלוֹם",
    "hex": "1f0be2d1e8d9ea20e9b8c1dcd5b9dd"
  },
  {
    "text": "العربية السلام",
    "hex": "13a7c4b9b1a8caa920a7c4b3c4a7c5"
  },
  {
    "text": "हिन्दी नमस्ते",
    "hex": "14b9bfa8cda6c020a8aeb8cda4c7"
  },
  {
    "text": "বাংলা ভাষা",
    "hex": "1f13acbe82b2be20adbeb7be"
  },
  {
    "text": "中文 日本語 한국어",
    "hex": "0f4e2d6587002065e5672c8a9e0020d55cad6dc5b4"
  },
  {
    "text": "🦉 😀 𐐀 𝄞",
    "hex": "0be1f389200b01ec80200b600880200b41a29e"
  },
  {
    "text": "\u0000\t\n\r\u0001",
    "hex": "00090a0d0101"
  },
  {
    "text": "﻿￿",
    "hex": "0efeff1f6880188dff1b8e800effff"
  },
  {
    "text": "󡝜򰤽􎲡󭵣񤻠񼏣񧍩𮙡􏓉󛘭𵛆󙿊𪫃򭄱񃢵輠񱋀𥷁󶟒𯁖𖄀񶍔␂򅦶󎀱򇌴񚵙񀆫򮽏򲜥𫐜󀵀򅪙𑿬媥򊪫󱍘񼿧󴬓󇗇",
    "hex": "0fdb45df5cda82dd3ddbfbdca1db77dd63d953dee0d9b0dfe3d95cdf69d879de61dbfddcc9db2dde2dd895dec6db27dfcad86adec3da74dd31d8cedcb58f20d984dec0d857ddc1db99dfd2d87cdc56d818dd00d998df54ef48820fd9d6ddb6daf8dc31d9dcdf34d92bdd59d8c0ddabda7bdf4fda89df25d86ddc1cdac3dd40d9d6de99d807dfec5aa5d9eadeabdb84df58d9b3dfe7db92df13daddddc7"
  },
  {
    "text": "郝򁼎򊞭󋜻򲀏󰬦𵧲񝕕󭢔񥑚󮺾𖔤𬕘򑕋􆹭򐮛𞪸񘘙㎋񭍄񣥩𓩸򠫘򯗈񅶸򹪵󬙚𚹶󯏘񩧞񅸄􊖑􋓗𭵕񟀑􊯌攔񖺃񠃠𻳙",
    "hex": "0e90dd0fd9c7df0ed9e9dfaddaeddf3bda88dc0fdb82df26d896ddf2d935dd55db76dc94d955dc5adb7bdebed819dd24d871dd58da05dd4bdbdbde6dda02df9bd83adeb8d921de19ef678b0fd974df44d94edd69d80ede78da42ded8da7dddc8d8d7ddb8daa6deb5db71de5ad82bde76db7cdfd8d966ddded8d7de04dbe9dd91dbeddcd7d877dd55d93cdc11dbeadfcc6514d91bde83d940dce0d8afdcd9"
  },
  {
    "text": "򲥹򙰹󦺥𧟻頻򾭍򊷲񌄖񐭵􄛷򭞉󷦱񶶀򍙶󆃼񵵹񚌹𵚐򋂹񘒶򟔁𦭸򻼗񸳃򤕝񻄀􌍍򦒈򻼁󰆚􏕫񂔧􁾃𞺌𵱜򰸰󤞠񁻚񒒌𝨳",
    "hex": "0fda8add79da27dc39db5bdea5d85ddffb983bdabadf4dd9ebddf2d8f0dd16d902df75dbd1def7da75df89db9eddb1d99bdd80d9f5de76dad8dcfcd997dd79d928df39d895de90d9ecdcb9d921dcb6da3ddd01d85adf78daafdf17d9a3dcc3da51dd5dd9acdd00dbf0df4dda59dc88daafdf01db80dd9adbfddd6bd8c9dd27dbc7df83d83bde8cd897dc5cda83de30db51dfa0d8c7dedad909dc8cd836de33"
  },
  {
    "text": "򙅝󣨫򊒒򔢗󭾠􊚲䐈󝡑𐢨󝑆򈉖򟣠񐙳񕻷򴊱򾴷򇧮􋯮󬊝􌕝𠓽񥑞񂯾󽳱󐧀𶊆񩹈󿎷󑥟𶑞󛩔񒂶񝍪򫛽򍾏𪸚𿤿񷑏񷍔񛎔",
    "hex": "0fda24dd5ddb4ede2bd9e9dc92da12dc97db77dfa0dbe9deb24408db36dc51d802dca8db35dc46d9e0de56da3edce0d901de73d917def7da90deb1dabbdd37d9deddeedbeedfeedb70de9ddbf1dd5dd841dcfdd955dc5ed8cadffedbb7dcf1db02ddc0d898de86d967de48dbbcdfb7db06dd5fd899dc5edb2ede54d908dcb6d934df6ada6ddefdd9f7df8fd86bde1ad8bedd3fd99ddc4fd99cdf54d92cdf94"
  },
  {
    "text": "򋺋򺹅󳓡󁫄𻨤򙝧񹕱𶗵񞏓񒮏񳶟򬆡󒓐񭂟聕񌔯񪓛󶺀󹝡󚴦򗗉򦯰򍾒𨟡𾦞麆򗱗񯕢򿰍񢋎񏨴򌚋𮋠󬐻𕜾񓻅񸧘𵜫񯹶",
    "hex": "0fd9efde8bdaabde45db8ddce1dac6dec4d8aede24da25df67d9a5dd71d899ddf5d938dfd3d90adf8fd98fdd9fda70dda1db09dcd0d974dc9f8055d8f1dd2fd969dcdbdb9bde80dba5df61db2bdd26da1dddc9da5adff0d9f7df92d861dfe1d8badd9e9e86da1fdc57d97ddd62dabfdc0dd948deced8fede34d9f1de8bd878dee0db71dc3bd815df3ed90fdec5d9a2ddd8d895df2bd97fde76"
  },
  {
    "text": "񜭐򱁰󾕬𥱢𑛅ꮵ񿘧㨚𳫕񟓵펖𾈓󽨊󞫥񮣺󍠙򚈆󼌸򦎖ꩦ򡧄󵛄񨵾񠞑񿊤ᴄ򩶱󷻃񟇴編񤷹𧭖򖁮񊻭񋏪􏣍򿤤򪲆񟵠",
    "hex": "0fd932df50da84dc70dbb9dd6cd857dc62d805dec5abb5d9bdde273a1ad88eded5d93ddcf5d396d8b8de13dbb6de0adb3adee5d97adcfadaf6dc19da28de06dbb0df38da58df96aa66da46ddc4db95dec4d963dd7ed941df91d9bcdea4ef3a840fda67ddb1db9fdec3d93cddf47de8d953ddf9d85edf56da18dc6ed8ebdeedd8ecdfeadbfedccddabedd24da6bdc86d93fdd60"
  },
  {
    "text": "򼚢񋯫𗶉񫌽􇲴񚥧񵿈󏟚􏍅𥨺񹞱򮤞񪊵񜔅񔫽򓳁捉󆝙𰤁򿷆򇰩񚭺񎊳𛌸񨛕񪷏򿻸񴔡򑐋򿘋𳌈򣳞􂯎򲡽󜝦񋔉򕴠􍾫󪱍񯆫",
    "hex": "0fdab1dea2d8eedfebd81fdd89d96cdf3ddbdfdcb4d92add67d997dfc8dafddfdadbfcdf45d856de3ad9a5dfb1da7add1ed968deb5d931dd05d912defdda0fdcc16349dad9df59d882dd01dabfddc6d9dfdc29d92adf7ad8f8deb3d82cdf38d961ded5d96bddcfdabfdef8d991dd21da05dc0bdabdde0bd88cdf08da4fdcdedbcadfceda8adc7ddb31df66d8eddd09da17dd20dbf7dfabdb6bdc4dd97cddab"
  },
  {
    "text": "󁞂𰆆󊿑𾖵𵻋㸁􅻢񮿉񞍅򨀘񆪉𐺟򌷚𛮬񶠹󞅆򀿨򒦲򲐤񡢋􄂄󸮐𰁳𥐗󅾵󼒿񟎯񊩾󡀭󐨪򟸤𷔁󡎀񠾴񲂞󲒛򵖍𯌋󥥌廎",
    "hex": "0fdac5df82d880dd86daebdfd1d8b9ddb5d897decb3e01dbd7dee2d97bdfc9d938df45da60dc18d8dade89d803de9fd9f3dddad82edfacd99adc39db38dd46d9c3dfe8da0addb2da89dc24d946dc8bdbd0dc84dba2df90d880dc73d855dc17dad7dfb5dbb1dcbfd93cdfafd8eade7edb44dc2ddb02de2ada3fde24d89ddd01db44df80d943dfb4d988dc9edb89dc9bda95dd8dd87cdf0bdb56dd4c5ece"
  },
  {
    "text": "񑹪󘙾갵󲾱񎌏󙃈񙽑񎋦􅞟򶺢񚦒򕭴񦈲򡊜򈓿縵􃮁𐻈񹥢󄽦񱞩񜇏򭵗٠􄯨𵀗񓅭􈿦񅾯򌞃򌶓򔋾񯳒򾚁򾘱򴝅𛀫񢦚񇏕",
    "hex": "0fd907de6adb21de7eac35db8bdfb1d8f8df0fdb24dcc8d927df51d8f8dee6dbd5df9fda9bdea2d92add92da16df74d958de32da44de9cd9e1dcff7e35dbcedf81d803dec8d9a6dd62dad3df66d985dfa9d930ddcfda77dd57e3e00fdbd2dfe8d894dc17d90cdd6ddbe3dfe6d8d7dfafef92e80fd9f1df83d9f3dd93da10defed97fdcd2dab9de81dab9de31da91df45d82cdc2bd94add9ad8dcdfd5"
  },
  {
    "text": "󎄐񉼗򵢨򐳤󋳤󥆾󻒞􀭸񍌧򧲰𺈅󿑼򪪌񺐵񠑯򳧇򰩡뮧򞒛򟿉񔏝󣵁𷒳𢟳𗹘񟁚󒭑𕍛󏠇򞞆󣱸񾰥𧣠𫔗󄖁򭗫󼦃𑛘񡤑򁬺",
    "hex": "0fdaf8dd10d8e7df17da96dca8da03dce4daefdce4db54ddbedbaddc9edbc2df78d8f4df27da5fdcb0d8a8de05dbbddc7cda6ade8cd9a9dc35d941dc6fda8eddc7da82de61bba7da39dc9bda3fdfc9d910dfdddb4fdd41d89ddcb3d849dff3d81fde58d93cdc5adb0adf51d814df5bdafedc07da39df86db4fdc78d9bbdc25d85edce0d86ddd17dad1dd81da75ddebdbb2dd83d805ded8d946dd11d9c6df3a"
  },
  {
    "text": "񰘍𕤿󶘷񆃹񒔣𧞨󍃁񣯗𲲒􁚜񉔔⛗𪻴򘇭򽔙􃮸𺞫⽣礟񹚜󐥂𗞡񏪳񧇘򊈼񀝄󠲸𰨸񴓒򱕚􏺱𓻸򡾔񹗦󑑁􃑿𚮆𳮟򫏐򱛛",
    "hex": "0fd981de0dd816dd3fdb99de37d8d8dcf9d909dd23d85ddfa8daf4dcc1d94edfd7d88bdc92dbc5de9cd8e5dd14ef4dd70fd86bdef4da20ddeddab5dd19dbcedfb8d8a9dfab2f63791fd9a5de9cdb02dd42d81ddfa1d8fedeb3d95cddd8d9e8de3cd8c1df44db43dcb8d882de38d991dcd2da85dd5adbffdeb1d80fdef8da47df94d9a5dde6db05dc41dbcddc7fd82adf86d88edf9fda6cdfd0da85dedb"
  },
  {
    "text": "󺢽􋋼򮽨덂𿂶򱧁㟘񦪋򷭯𛂇򼉙󓽨򇦈𿏫򇵛򪗸񙀀𒦺򓃨򝓓򳞘񹹪񒉂򰿞󔺎򰮕𙉑񑩁𢶥𠲌󔿜򎃌򟦚󯦉􏊼񌦟󕿚𘜰󅗠򠀖",
    "hex": "0fdbaadcbddbecdefcda7bdf68b342d8bcdcb6da86ddc137d8d95ade8bda9edf6fd82cdc87dab0de59db0fdf68d9dedd88d8bcdfebd9dfdd5bda69ddf8d924dc00d80addbada0cdce8da35dcd3da8ddf98d9a7de6ad908de42da83dfdedb13de8eda82df95d824de51d906de41d84bdda5d843dc8cdb13dfdcd9f8dcccda3edd9adb7edd89dbfcdebcd8f2dd9fdb17dfdad821df30dad5dde0da40dc16"
  },
  {
    "text": "񥺄򹧲𪤡򭲄򓨾󭲻񕁡򶤏𡸸𞖴񜏒񓗁󓲧񕠘񤅂򅻾󩛀𰊩񯀔򌆕𥸵񾍰𥡂󆎤񩐿񇾾񓱹󻐈𙴠𕗣񊛇󢛳򖴊񣻩𙇈򊄅𗗹񪏐",
    "hex": "0fd957de84daa6ddf2d86add21da77dc84f0e0deda0ede3edb77dcbbd914dc61da9add0fd847de38d839ddb4d930dfd2d90dddc1db0fdca7d916dc18d950dd42d9d7defedb65dec0d880dea9d97cdc14d9f0dd95d857de35d9b8df70d856dc42dad8dfa4d965dc3fd8dfdfbed90fdc79dbaddc08d827dd20d815dde3d8e9dec7db49def3da1bdd0ad94fdee9d824ddc8d9e8dd05d81dddf9d968dfd0"
  },
  {
    "text": "񉶍򮦧𐂠󅅖㫆䳭󣡊󱺛𤸽򔣑򋕞󇼔񾮄󻋺􌰤򙍅𽄦񃭋򎻏򭶋􅶸󝧢򭪎󛵚𩃧򿎾񌟁񥋀򬬀󕽄􂻱𼎣򰄅􇫄򺩟𵲴󈼻􋛉𖬖",
    "hex": "0fd8e7dd8dda7adda7d800dca0dad4dd563ac64ceddb4edc4adb87de9bd853de3dda12dcd1d9eddd5edadfdf14d9badf84dbacdefadbf3dc24da24df45d8b4dd26d8cedf4bf0f18cd9fbdecfda77dd8bdbd7ddb8db36dde2da76de8edb2fdd5ad864dce7dabcdfbed8f1dfc1d954dec0da72df00db17df44dbcbdef1d8b0dfa3da80dd05dbdedec4daaade5fd897dcb4dae3df3bdbeddec9d81adf16"
  },
  {
    "text": "򥾋贑񈪀󵓠𪽹񧅄𕆧󨵱𴶊􎭖񂳚됢󌹩񈌽񹔦𗥋򙠮놎􋍜򔜔򸘆򎗃񴾶􈣋𫷦𐍼󡜣󨜍򋒛󨚞󸙊􀕘񻄮򵃢񐚍񝛎󎽴򊦉񸑩𺣐",
    "hex": "0fda57df8b8d11d8e2de80db95dce0d86bdf79d95cdd44d814dda7db63dd71d893dd8adbfadf56d8cbdcdab422daf3de69d8e0df3dd9a5dd26d81edd4bda26dc2eb18edbecdf5cda11df14daa1de06d9f9ddc3d993dfb6dbe2dccbd86fdde6d800df7cdb45df23db61df0dd9eddc9bdb61de9edba1de4adbc1dd58d9acdd2eda94dce2d901de8dd935decedafbdf74d9eadd89d9a1dc69d8aadcd0"
  },
  {
    "text": "󟜺𧯖򀴫󐉺򫅾󻘌𷠶򆼨󺄼􆨚󫪱򃴒򚼈񊤭񰤕򥋃񄤘񺿒񗹧󘀙򤣳򱪡𕵜ⓖ򲉣퍸񂱃𘓸󊶧󪹛󦜷􉮁𔟵􀯿𝮧뉷򵲃𓍃􊾁򘸆",
    "hex": "0fdb3ddf3ad85edfd6d9c3dd2bdb00de7ada6cdd7edbadde0cd89edc36d9dbdf28dba8dd3cdbdade1adb6edeb1d9cfdd12da2bdf08d8eadd2dd982dd15da54dec3d8d2dd18d9abdfd2d91fde67db20dc19da52dcf3da86dea1d817dd5cef49d60fda88de63d378d8cbdc43d821dcf8daebdda7db6bde5bdb59df37dbe6df81d811dff5dbc2dfffd836dfa7b277da97dc83d80cdf43dbebdf81da23de06"
  },
  {
    "text": "򃉝򄭶󪙧񋾠𥦃𻱨𩤶󬽖榅񼙖򖄟󮮰􅽮󅄱򊕑򡙓󲤔񮟅񂢟񂷑𫲢𢶵󉷮񺙍𭕔괠򱑔񒣉󏴶𯚤򍆖𥇃񕇚󅏽򔕂񄙦𛰰𢑨񒁘򔼪",
    "hex": "0fd9ccde5dd9d2df76db69de67d8efdfa0d856dd83d8afdc68d866dd36db73df566985d9b1de56da18dd1fdb7adfb0dbd7df6edad4dd31d9e9dd51da45de53db8add14d979dfc5d8cadc9fd8cbddd1d86fdca2d84bddb5dae7ddeed9a9de4dd875dd54ad20da85dc54d90adcc9daffdd36d87ddea4d9f4dd96d854ddc3d914dddadad4dffdda11dd42d8d1de66d82fdc30d849dc68d908dc58da13df2a"
  },
  {
    "text": "񦀭򉼓󬫍򃲂𖡅񗳂󙜞𑞟󬀒🅞򀔔𹭧򽟕󄵰䛦񳏑򶨕񷋳򮛪򠔳򱻺󛸮򩽼񆢄􍣈󟅉񵖋񙃃󉐴񱬮􄙀󆤳􆄥񯝷񵆨򝧛񼱇򋓂󚗵󷭗",
    "hex": "0fd958dc2dd9e7df13db72decdd9cfdc82d81adc45d91fdcc2db25df1ed805df9fdb70dc12d83cdd5ed9c1dd14d8a6df67dab5dfd5dad3dd7046e6d98cdfd1da9ade15d99cdef3da79deeada41dd33da87defadb2fde2eda67df7cd8dadc84dbf6dcc8db3cdd49d995dd8bd924dcc3dae5dc34d986df2edbd1de40dadadd33dbd8dd25d97ddf77d994dda8da36dddbd9b3dc47d9eddcc2db29ddf5db9edf57"
  },
  {
    "text": "󰫁󁯵򚧊񪑣򳫨𯾰񱇒󙠽𱬎󆇃󭑻𬡡񢙒Ự𰢢󰜏񬤚󮊇󚯬򔀙򐋢񅲋􆹙䜁󿣾󗍜񆂉񘭏𧆺󢢘򸼘񂼌﹌񉨛򬐺𑌣񤐤񡳦񵌖𧢄",
    "hex": "0fdb82dec1dac6dff5da2addcad969dc63da8edee8d87fdfb0d984ddd2db26dc3dd886df0edad8ddc3db75dc7bd872dc61d949de52ef3df00fd882dca2db81df0fd972dd1adb78de87db2adfecda10dc19da00dee2d8d7dc8bdbdbde594701dbbedcfedb1cdf5cd8d8dc89d922df4fd85cddbadb4adc98daa3df18d8cbdf0ce8a4cc0fd8e6de1bda71dc3ad804df23d951dc24d947dce6d994df16d85edc84"
  },
  {
    "text": "󇊼𡱈򥋕㶺񗒗󾹸𭀗񄖪𺅁󖟛򃒭󽃰򱠂񭴸􈦹򇨱􂸦񅘀𘙨񘧀񼆙𗷀򦄼􇌪򁻛򡾼񩵵򴵂󫅋򴩦􎊯񾺵򔠟󤌓󢏺񞉛񬈉􈘐񘉢򹏢",
    "hex": "0fdadcdebcd847dc48da54ded53dbad91ddc97dbbbde78d874dc17d8d1ddaad8a8dd41db19dfdbd9cddcaddbb4dcf0da86dc02d977dd38dbe2ddb9d9dede31dbcbde26d8d5de00d821de68d922ddc0d9b0dd99d81fddc0da58dd3cdbdcdf2ad9c7dedbda47dfbcd967dd75da93dd42db6cdd4bda92de66dbf8deafd9bbdeb5da12dc1fdb50df13db48dffad938de5bd970de09dbe1de10d920de62daa4dfe2"
  },
  {
    "text": "󀼵񖇧񆹻󘯙󏾥𐐿󳱝񝳧󙍘󂆿󞮥򠴺񻂘𸾛򇧭󧦑𫚍𤗄󆯑𲧣񻉙󈌶񘩴򌽦􃵧򲰏갓󑼺𨔲󋳱񊌪񡁗򚻌󾟗񎽸򼃙񾷡񧭹",
    "hex": "0fdac3df35d918dde7d8dbde7bdb22dfd9daffdfa5d801dc3fdb8fdc5dd937dce7db24df58dac8ddbfdb3adfa5da43dd3ad9acdc98d8a3df9bd9deddeddb5edd91d86dde8dd851ddc4dadadfd1f0f18bd88adde3d9acde59dae0df36d922de74d9f3df66dbcfdd67da8bdc0fac13db07df3ad861dd32daefdcf1d8e8df2ad944dc57f0ed6eda2bdeccdbb9dfd7d8fbdf78dab0dcd9d9bbdde1d95edf79"
  },
  {
    "text": "󳚁𙨶񊊋򠂺𪏱𧰩󟪍񵴻ǰ񅜫򥟜󾳦𧷝󶬻򺪙񲍗򼩯񹫉򉉈򭘉񹻈񥟺򼢖򟣿򳍺񔵬𿐯񊉬񎈔󁗃򴨆򗓧𻩸𜾬􁘈􊠀񺟫󜲛𗕡񓀹",
    "hex": "0fdb8dde81d826de36d8e8de8bda40dcbad868dff1d85fdc29db3ede8dd997dd3bef03f00fd8d5df2bda55dfdcdbbbdce6d85fdddddb9adf3bdaaade99d988df57dab2de6fd9a6dec9d9e4de48da75de09d9a7dec8d955dffadab2dc96da3edcffda8cdf7ad913dd6cd8bddc2fd8e8de6cd8f8de14dac5ddc3da92de06da1ddce7d8aede78d833dfacdbc5de08dbeadc00d9a9dfebdb33dc9bd81ddd61d90cdc39"
  },
  {
    "text": "򕺷㸗獝򎒈󤦂󾐌󿨭򗦲񔻼񋁭𐐨𢑌𓕵󡥹󃑾𜚦񴌁󡠴񏣠򫗳𺐸ꂙ󫁬ꪨ󤢍򆪱󬵢󚚅𜞀򧺵񓲷󘓗󵐯򍦄񽬓󮍹񶨃𣌁񸠰",
    "hex": "0fda17deb73e17735dd9f9dc88db52dd82dbb9dc0cdbbede2dda1eddb2d913defcd8ecdc6dd801dc28d849dc4cd80ddd75db46dd79dacddc7ed831dea6d990df01db46dc34d8fedce0da6dddf3d8a9dc38a099db6cdc6caaa8db52dc8dd9dadeb1db73dd62db29de85d831df80da5fdeb5d90fdcb7db21dcd7db95dc2fd9f6dd84d9b6df13db78df79d99ade03d84cdf01d9a2dc30"
  },
  {
    "text": "򮦡󢢉񿗀񵆜񈜜񧙘񴴱󵓃򿜒񺹞򋮝󻣳񆃅󦄞󼫴􆐝𦜫𾇽񡲹󔦱򬺬􋈳򁼅𵦺򢜇񷾌񔂱񜣃􏆲󨎧򮙁󔂤𗛪𣰹򛋹􇇎󄌢􅰬ꤽ璴",
    "hex": "0fda7adda1db4adc89d9bdddc0d994dd9cd8e1df1cd95dde58d993dd31db95dcc3dabddf12d9abde5ed9eedf9ddbaedcf3d8d8dcc5db58dd1edbb2def4dbd9dc1dd859df2bd8b8ddfdd947dcb9db12ddb1da73deacdbecde33d9c7df05d896ddbada49df07d99fdf8cd910dcb1d932dcc3dbfcddb2db60dfa7da79de41db10dca4d81ddeead84fdc39da2cdef9dbdcddcedad0df22dbd7dc2ca93d74b4"
  },
  {
    "text": "򢢣򠗤󦌂򊄻񰀴󹛧󚂛𮓾𔹭󌌃񶻜򫲉󤾏񺸻򇈓񙮉𚔴񅮉񆺐􁼇򎮦񗕓򀰂򟖛򺬨񁻥򏘺򖿳󤚏񫈍񏝨󌍀󍟪򖍯񔅿󦌣񙩱𨔂炂񃰾",
    "hex": "0fda4adca3da41dde4db58df02d9e8dd3bd980dc34dba5dee7db28dc9bd879dcfed813de6ddaf0df03d99bdedcda6fdc89db53df8fd9abde3bd9dcde13d926df89d829dd34d8d6df89d8dbde90dbc7df07d9fadfa6d91ddd53d9c3dc02da3ddd9bdaaadf28d8c7dee5d9fdde3ada1bdff3db51de8fd96cde0dd8fddf68daf0df40daf5dfeada18df6fd910dd7fdb58df23d926de71d861dd027082d8cfdc3e"
  },
  {
    "text": "򒓥𝖣􈀌󖠯󈂬򛩞𒙽򱝬𰲑񇷑񚋷񼞀򣓘󨾛􄮈􀨕𔦦󴲛򉌈𹅌󖏝𛱙鸍󞩩󤀽􌜯鳽񌸤񛖅񡋊𳈘󽝪񸙅󤣝򧾽񭣞񕌁򖥘񶌃򌿬",
    "hex": "0fda09dce5d835dda3dbe0dc0cdb1adc2fdae0dcacda2ede5ed809de7dda85df6cd883dc91d8dfddd1d928def7d9b1df80da4ddcd8db63df9bdbd2df88dbc2de15d812dda6db93dc9bd9e4df08d8a4dd4cdb18dfddd82fdc599e0ddb3ade69db50dc3ddbf1df2fd87ede0cd8f3de24d92ddd85d944decad88cde18dbb5df6ad9a1de45db52dcddda5fdfbdd976dcded914df01da1add58d998df03d9f3dfec"
  },
  {
    "text": "𲤦󨑃񆝿񪒛󙣩󷇇񽾄􀩀𒚱󋄸򨏉𧽪򻰼􄍉򝥬╋񂤮񕸻򅩗󴁷󷋛򄽸򣄟򿇶𲟙񦟅񊒄􈥏򇒍𮦢𜃒񓸩򈿪񄌯姣𰜱򽤟𵙇𬸂𥕦",
    "hex": "0fd88add26db61dc43d8d9df7fd969dc9bdb26dce9db9cddc7d9b7df84dbc2de40d809deb1daecdd38da60dfc9d85fdf6adaafdc3cdbd0df49da36dd6cef4acb0fd8cadd2ed917de3bd9d6de57db90dc77db9cdedbd9d3df78da4cdd1fdabcddf6d889dfd9d959dfc5d8e9dc84dbe2dd4fd9dddc8dd87adda2d830dcd2d90fde29d9e3dfead8d0df2f59e3d881df31dab6dd1fd895de47d873de02d855dd66"
  },
  {
    "text": "򾞍􎳕򟸎򸷖򸢴񢽔󋩿򉀿𲪞򾣐􎗫􉒠񞚫𨫉󲮒􈋃򉲧񯹖󣉜𥖚鍡򩵔􉋿򙮾􅑁򷿺񓟜󱓝􊰬󞣉񊃠񌯋𣅆񲢭𢌍񤬸텱򐿨򙩱󚁟",
    "hex": "0fdab9df8ddbfbdcd5da3fde0edaa3ddd6daa2dcb4d94bdf54daeede7fd9e4dc3fd88ade9edabadcd0dbf9ddebdbe5dca0d939deabd862dec9db8adf92dbe0dec3d9e7dca7d97fde56db4cde5cd855dd9a9361da67dd54dbe4deffda26dfbedbd5dc41da9fdffad90ddfdcdb85dcdddbebdc2cdb3adcc9d8e8dce0d8f2dfcbd84cdd46d98adcadd848df0dd952df38d171da03dfe8da26de71db28dc5f"
  },
  {
    "text": "󻗼򧁇񻇿򾐥󇒃񋸝񉏬󰸆񗿍ꨮ괲󶉀񎂇󹮷󚭅뭬󲈄𾐏󄕁貰񣴖󱜙򯀆𨝂𸴢󌾜󙘸򢿷񸜋򼼱򡂞񺯷򁡍󡟤𜆓󬶪񛜃𹚌𧸩",
    "hex": "0fdbadddfcda5cdc47d9acddffdab9dc25dadddc83d8efde1dd8e4dfecdb83de06d91fdfcdaa2ead32db98de40d8f8dc87dba6dfb7db2adf45bb6cdb88de04d8b9dc0fdad1dd418cb0d94fdd16db85df19da7cdc06d861df42f0e95bd8a3dd22daf3df9cdb25de38da4bdff7d9a1df0bdab3df31da44dc9ed9aadff7d9c6dc4ddb45dfe4d830dd93db73ddaad92ddf03d8a5de8cd85fde29"
  },
  {
    "text": "񥬺񈱒򯌺񭀮鉃𪆚򙢂󺀾񍃐񢘅񉠔񝄊􋑬򕧖񀩛𬋕񵐊깼򶦸𗦍򺟀𸝕󌝀󞐭俭嫺𡘎򕫟񱁈𒨷񌫵򣺷󎺓򩴴񱌽󐎳𪍂󌼢𬞏",
    "hex": "0fd956df3ad8e3dc52da7cdf3ad974dc2e9243f0f0a9d868dd9ada26dc82dba8dc3ed8f4dcd0d949de05d8e6dc14d934dd0adbeddc6cda16ddd6d8c2de5bd870ded5d995dc0aae7cda9addb8d81edd8ddaa9dfc0d8a1df55daf1df40db39dc2d4fed5afad845de0eda16dedfd984dc48d80ade37d8f2def5da4fdeb7dafbde93da67dd34d984df3ddb00dfb3d868df42daf3df22d871df8f"
  },
  {
    "text": "󢸉𨊟󦧉󲕓򻵙򅂢𴚾𰙇𕙉򭍽𧌛򏹟󅾽򹘺򲥹񅙱󝽶􃢨򙆛򣬰𠂅񚉝󣰪񯫳󎛯󵘃􈲽򌑡󸃷𧏹񮠠􇈂񲨳􄱃󇑡􄈻􉯤󞼭򌖉󏏊",
    "hex": "0fdb4bde09d860de9fdb5addc9db89dd53daafdd59d9d4dca2d891debed881de47d815de49da74df7dd85cdf1bd9ffde5fdad7dfbddaa5de3ada8add79d8d5de71db37df76dbcedca8da24dd9bda4edf30d840dc85d928de5ddb4fdc2ad97edef3daf9deefdb95de03dbe3dcbdd9f1dc61dba0dcf7d85cdff9d97adc20dbdcde02d98ade33dbd3dc43dadddc61dbd0de3bdbe6dfe4db3bdf2dd9f1dd89dafcdfca"
  },
  {
    "text": "񵵡󱽖򛕣򃙧󲐢𸉺򭊈񜑎𹪥򩋹񣿤𶩯𿴁󎞻򙧘􍻐􎨽󞃺󕋃񴲦󺱿󹢙𪉅򀔟񐏽󒒢񄚇󘚹𓛹򞽲񕡂󉅒󇬣򌢊򶬏񔐜🹻",
    "hex": "0fd997dd61db87df56da2ddd63d9cdde67db89dc22d8a0de7ada74de88f0e675d931dc4ed8a6dea5da64def9d94fdfe4d89ade6fd8bfdd01daf9dfbbda26ddd8dbf7ded0dbfade3ddb38dcfadb14dec3d993dca6dbabdc7fdba6dc99d868de45d9c1dd1fd900dffddb09dca2d8d1de87ef97d90fdb21deb9d80ddef9da3bdf72d916dc42dae4dd52dadedf23d9f2dc8ada9adf0fd911dc1cf0e89ed83fde7b"
  },
  {
    "text": "󖐛󧙛񬵯񂂵䎊􋙗𿥍𩡫󉨪󅮅򉭠󓸃񙆶򋤈󫁦򽤠򙥘󽧱𬆋򱛆񲇉󒈪𘞇𪹳򫉏𬷔󑚛򣓾󵱤󌥁𡊌򉐦󖹍󰟌𬂅򷇒􉞀􊋩񊙬𵟺",
    "hex": "0fdb19dc1bdb5dde5bd973dd6fd8c8dcb5438adbedde57d8bedd4dd866dc6bdae6de2adad6df85d9e6df60db0fde03d924ddb6d9eedd08db6cdc66dab6dd20da26dd58dbb6ddf1d870dd8bda85dec6d988ddc9db08de2ad821df87d86bde73da6cde4fd873ddd4db05de9bda4ddcfedb97dc64daf2dd41d844de8cd9e5dc26db1bde4ddb81dfccd870dc85da9cddd2dbe5df80dbe8dee9d8e9de6cd895dffa"
  },
  {
    "text": "񶯽񾾏򆁟󸻑򎚷򪓌񐒇󏦎󂣔𣏕񬛲񾫴񥵇󀩻𴷣𮼬򸵪𶡦􇃉ங󨂿𨿣򽚊򯴼󳬜񄰥񦵌󖣨񞁏򙭺󆁂󣻼󇆩󚺖򂿓񢝐󓑌򻅳𪩾󙁟",
    "hex": "0fd99adffdd9bbdf8fd9d8dc5fdba3ded1d9f9deb7da69dcccd901dc87dafedd8edacadcd4ef9dd10fd971def2d9badef4d957dd47dac2de7bd893dde3d87bdf2cdaa3dd6ad89adc66dbdcdcc9e817990fdb60dcbfd863dfe3dab5de8ada7fdd3cdb8edf1cd8d3dc25d95bdd4cdb1adce8d938dc4fda26df7adad8dc42db4fdefcdadcdda9db2bde96d9cbdfd3d949df50db0ddc4cdaacdd73d86ade7edb24dc5f"
  },
  {
    "text": "􆉳󢎆򧎳󺐣𖧶񇻝󡡎󌬱󕤼񨇨던󠒰󽻌񗰣𮽩񬦛򫀇򤼽񝽉񸔬򤐠񉦛󰆒񤯔񟎽󮙋􃾕󺋋宋򁏾򉠶󎂇𔪠􊈎󖤂􎡅򕥋򙯼",
    "hex": "0fdbd8de73db48df86da5cdfb3dba9dc23d81addf6d8dfdedddb46dc4edaf2df31db16dd3cd960dde8b358db41dcb0dbb7deccd91fdc23d87bdf69d972dd9bda6cdc07da53df3dd937df49d9a1dd2cda51dc20d8e6dd9bdb80dd92f0e708d952dfd4d93cdfbddb79de4bdbcfdf95dba8decb5b8bf0e6e5d9c4dffed9e6dc36daf8dc87d812dea0dbe8de0edb1add02dbfadc45da16dd4bda26dffc"
  },
  {
    "text": "򝑽򒷢񦞠񢔜󢹮𐆌񪱊󀴽򥩳䦶𻟦񃅬񗌄󕧩𪅺񷖚󈹒酀񴷇򤐀𴿄򶔳󁞼񌽝򬞾򑵮񞅢󶢲꺻񶆛򳷸􉡟󠩖󋂾𷚞񷍻񠧏𵏻𷱦󹾗",
    "hex": "0fda35dc7dda0bdde2d959dfa0d949dd1cdb4bde6ed800dd8cd96bdc4adac3dd3dda56de7349b6d8addfe6d8ccdd6cd91cdf04db16dde9d868dd7ad99ddd9adae3de529140d993ddc7da51dc00d893dfc4da99dd33dac5dfbcd8f3df5dda71dfbeda07dd6ed938dd62db9adcb2aebbd998dd9bda8fddf8dbe6dc5fdb42de56daecdcbed89dde9ed99cdf7bd942ddcfd894dffbd89fdc66dba7df97"
  },
  {
    "text": "󸫼򪪕򦨲󱐗򯃘򼧻㵌񻍛𺿖𻲂񵡥󘔛󕩺𖝬򭀽𝻱󕀎򣔿񍔢񟞺􌨖󈍗񆸼󊇳󰡰񋮖򋓹􁠭𫡓􍈩𼐐􀆵𡑴򒯒񮔍𳰲񐲸񚿽𼶧",
    "hex": "0fdba2defcda6ade95da5ade32db85dc17da7cdcd8dab2ddfb3d4cd9acdf5bd8abdfd6d8afdc82d996dc65db21dd1bdb16de7ad819df6cda74dc3dd837def1db14dc0eda4ddd3fd8f5dd22d93ddfbadbf2de16dae0df57d8dbde3cdae8ddf3db82dc70d8eedf96d9eddcf9dbc6dc2dd86edc53dbf4de29d8b1dc10dbc0ddb5d845dc74da0adfd2d979dd0dd88fdc32d903dcb8d92bdffdd8b3dda7"
  },
  {
    "text": "򙎁򛷧񓰲񁡡𚖁𭮅󼗹񼬇󑕶󖔫𢌻򤉓򟰜󤘷񹔄󅎩򾆳򭢝󣩠쩏򞲖󀄛񫍖񓌺󷡬󦐴򳗊񈦙񍮌򍔘񗫶󼣫򡓜񺒀񁥋󔤚򛵞򰝕񚶅򬦉",
    "hex": "0fda24df81da2fdde7d90fdc32d8c6dc61d829dd81d876df85dbb1ddf9d9b2df07db05dd76db19dd2bd848df3bda50de53da3fdc1cdb51de37d9a5dd04dad4dfa9dab8ddb3da76dc9ddb4ede60ca4fda3bdc96dac0dd1bd96cdf56d90cdf3adb9edc6cdb59dc34da8dddcad8e2dd99d8f6df8cd9f5dd18d91edef6dbb2dcebda45dcdcd9a9dc80d8c6dd4bdb12dd1ada2fdd5eda81df55d92bdd85da72dd89"
  },
  {
    "text": "򸏉򩼖󎬝񜣧𝻨񾵫𤑪򮰬󩶎񳿄𭋗򶓮򶶣𩾗󔇮𾵅󱘶󛱔󰸏񱱘󥢩򔽀򠛺򼉮򩀝򠭧𝵁򓝏󙤋򨓬򶕑󇍜𘕏𨷂𾪖񝅆󕘶󗹶򚁉񢪸",
    "hex": "0fdaa0dfc9da67df16dafadf1dd932dce7d837dee8d9bbdd6bd851dc6ada7bdc2cdb67dd8ed98fdfc4d874ded7da99dceeda9bdda3d867df97db10ddeed8bbdd45db85de36db2fdc54db83de0fd987dc58db56dca9da13df40da41defadab0de6eda64dc1dda42df67d837dd41da0ddf4fdb26dd0bda61dcecda99dd51dadcdf5cd821dd4fd863ddc2d8bade96d934dd46db15de36db1fde76da28dc49d94adeb8"
  },
  {
    "text": "􃸳𤓢󼀩򭞅𴩣񛒽򶏚򶆹򠐅󼙳򥽕򬳸󲦉򚤔񶏠񯢢񑩙򎕠񅣻򷈇񪩹񐘝󵞏򒪳󡾒򵁾󑐩򣗋󠦦򝡜􉆴򲃛󒩄󸩀񺝰򑆬񝥅񂔱󂲳󡺉",
    "hex": "0fdbcfde33d851dce2dbb0dc29da75df85d892de63d92ddcbdda98dfdada98ddb9da41dc05dbb1de73da57df55da73dcf8db8add89da2add14d998dfe0d97edca2d906de59d9f9dd60d8d6dcfbda9cde07d96ade79d901de1ddb95df8fda0adeb3db47df92da94dc7edb05dc29da4dddcbdb42dda6da36dc5cdbe4ddb4da88dcdbdb0ade44dba2de40d9a9df70da04ddacd936dd45d8c9dd31dacbdcb3db47de89"
  }
]
"""#
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(json.utf8))
        for vector in vectors {
            let hex = Array(vector.hex.utf8)
            let bytes = stride(from: 0, to: hex.count, by: 2).map { UInt8(String(decoding: hex[$0..<$0+2], as: UTF8.self), radix: 16)! }
            #expect(try SCSUDecoder.decode(Data(bytes)) == vector.text)
        }
    }
    @Test func malformedCommandsSurrogatesAndBudgetsFailExplicitly() throws {
        for bytes: [UInt8] in [[0x01], [0x0e, 0], [0x0f, 0], [0x18], [0x0b, 0], [0x0f, 0xf0, 0], [0x0f, 0xf1, 0]] {
            #expect(throws: SCSUDecoder.Failure.truncated) { try SCSUDecoder.decode(Data(bytes)) }
        }
        for bytes: [UInt8] in [[0x0c], [0x18, 0], [0x18, 0xa8], [0x0f, 0xf2]] {
            #expect(throws: SCSUDecoder.Failure.reserved) { try SCSUDecoder.decode(Data(bytes)) }
        }
        #expect(throws: SCSUDecoder.Failure.invalidUnicode) { try SCSUDecoder.decode(Data([0x0e, 0xd8, 0])) }
        #expect(throws: SCSUDecoder.Failure.limitExceeded) { try SCSUDecoder.decode(Data("abc".utf8), maximumUTF16Units: 2) }
        #expect(throws: SCSUDecoder.Failure.limitExceeded) { try SCSUDecoder.decode(Data(), maximumUTF16Units: -1) }
    }
}
