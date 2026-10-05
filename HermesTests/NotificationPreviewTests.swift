import XCTest
import CryptoKit
@testable import Hermes

final class NotificationPreviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1800000000)
    private let secret = Data(0..<32)
    private var fixtures: [[AnyHashable: Any]] {
        let json = #"""
[{"reference": "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8", "encrypted": {"v": 1, "kid": "AAECAwQFBgcICQoLDA0ODw", "data": "teu-875oN-v-LN8Ht1C8zNbHb6elDvqI8Q92vvWqdFUv1-ZndheGtSRD_X3_A1TGCjrByqfLrG_BNCrQquNkFNR4qO0usn5Z5apUvycPP-2_5HD6EaD0QFK6rdSbVJNQSFUrnw9bg6SS1DfumSzdim-jVkfcttrNqOxrglhbE9bHO0QuwnNDV_byfobCHvr0wY9DCWE6QIctX2xGjVKlKRj4eDTE38_OfTHl-0i0joSMMNypEnK9stXs4P2_dkv_tZuHeo8VjRsd_iH2_67_zWVNS4UqZqQQhXr2tSelbQtE2V2O3cMMNx8IWAk47Uf8wEh9976BdRqXMCfbBW7OirYD0zd1qwdTUhlk4gLAgWAwyGa-h6iZupF_PdVetd96qvWjc6UoGeMzWogLfz93ZgxDXT4ubxo_Ed6H21rWMXGQFl8lAzqfgph8ZsWN1PClwxiH2P9t_d2DgOCvE1w9Ag5ztDs261-A1N-SAS7tu29kRQ0uvlOagc2fHQ0Ykv7dgsBdPjLZBXN28U3f21JE7ewJlOE1X-lMbR5M3Le4_k9roLf-scwo8puiu_nhI8_-TKnKcRZYVXHhQARmlQ6Q8WwHmIpQeXTUFFd503Kpwt18oCLLvvWHtHl9fjxpMDP4GVD3DYaXAZRXVMSQjp_hQX2pIq4kQ67Tap1XWj6szUn4K4ar_apTIzmAqaghsCJA-98jXwBcl2H0Oxq2Fgq2EeRh7r1_ZEZ7zSoMpUxNnEzrlHlAQp845HCYUNe-zlYBAmBmWYSPGr-eMe6SGP2SVmEknmR_CN301HmT7MoIx7LiA2xe_6ThxtTqpE4ck2w90EvdS75Z5TWmoE1uNc3Dn3KhtPLh8rSvNK6Zcl8OtoFOyE3dDK1Mt4VYrycGsPoGcF0ZWq89l5rRIsZKLXOlfq_lEuBKR8qtHMnFxM_K6gqRdf-dStf3IXXIjzSrFaRRKIV4o4s1t3y6IxBeIWoiszMcleE2AusWT-Se5FPZUgj5ulY1T3uFKEoB1pL7hg9uAnkg-1c5NFeOYjI8Igdr4jfh7MHI0LYWDKQ-mkRw1Jmdp5lzUffaCaURezzncCV5r31LA6b8vkn0koWGWvxzFtV-jQ8JfzJTIIObLxpbfYfuJ0YO2-xw2bNR6oPnXtDuwzY4WFxu7_EL3Ujsj2Jcx5nCtWP3iR0hT8Ar184lsB-XkhzUxc2XQuiphoftE65sSNKiNvjI0DoRrgCSWrbECtEamD4EXrCNKkWBWeH8i-LsRKZ6EIOcDV8I4F4exuX45CRCbJNJ7Dtr_4iyrkrpUqg9MQ9f-ZAzeo_EtjR4LTcA6DLfr_-n1DH8joPEsRI_AtmYUCfnQ6woZtt4oCpFwl3wspLghHI_dhHkxvyXTjSXrCEvJntU3XnLhJ0"}}, {"reference": "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8", "encrypted": {"v": 1, "kid": "AAECAwQFBgcICQoLDA0ODw", "data": "kA8ZuBO10usBW7vV-HEyfgAjMFMA-7XdT7jhUiAcK_mVLdqyfxw4PWmkkODaIhBJVaF19wYhUCzi9A62ee1LdcOWjl08j_TtN4ej8hgc_sRVykBtspEU0frGPaUGK95_iwsKO_LeBRuGyX6PsVuEyrgOnQeH9gZxhPaxM-JnWWQRmMEW8jh42MvoTnj3RPpBzKdsUndh9rQZ-Y9sQRxSjOtWUFgaiGPETEpFahB9j75dWcXIxgeceb7LVDpy-TWvYIiJobyRioBRSBko1HXPcOzJPesgx3yy0N8LGWDH5HvzMxp2W05a5jhMxqcqoWbPvQZY8b54vFyOdTY8YFLRjGhakGrirstGjxj2WZT60p6b-LDj-_ylnOl4HwOgpOmglaCUDCdIX058OEkOuknrbXAuMJIl-2W6k8jzUZxxhPY52zwJL176hNHKb9tqCUtMr73C-sOsllDBCtMPsHxKRrRBLZU2ThhN2oeXEHBt2blXb2xMqDxkrT0ksiUZW1SIoMHBQB0DF9N7JZO1xuF7TtXO2GriTHFkkbLR5QARlRMHi8OMSSQ4NneUS6WirddNRL7IJFnNh8r7Gvv2z_hwGiscE5I9WFQbwReLny31sHUJ87O_dBsVA0OoyYv_DrtgszY2A9EsaaZRUOeDeX3KqpAo0W0lbgMZET_tDpySPMTp59y9sgOi3Em7mfyzcA3K_2J4hpntqWbLGteSmiXh7w8FsKNYRVvvfN4nA8im_Sf9EoR8EO5bUKdDPx0ZkZIdpSz6FXMvZvYruLjz6fIOyNEUHNIlUZ__PHgpBYVbAWHb0RH_Gu1ZYKCx09OMzJWc06JHGdda92Q4xnQjnHBd517g11kWEj7NKnHA22xYcheHRJFSQ2TrQCRx-mUmShYln1jAVYD23DSf7HY1rLxYp8xx61MUSUDgiR7I8rykWV16SX9gRzU8BGhygoWuqt_4pUFdH_1MhAytUBP0_UVQO1VFvMdGWNuvQ4zkdEieHSEmv-HoD4ioHsNT_ol8u3188CRjhKTdQ1w4pa1P9a4QECT3AMWkL7lhNGqpUdDERKAnBXtcgUauFjw5_dqJimsFlvWSM3nzq4X6rwTV3inxonh1X47kiTWMZSNgSKh7G6bIPth5oeOz5wjUShcmT95VF8HmYSR2sFiVK1aFOzjUzlzVe9pwumHOxjSpTtc9ko3CiHb_YGxp84x8RcZ6URW2Gg3CqCcuCt7rdo7-8J6TmhBXgmdmtSh5BiEJU4GuIbzeHAq7v23eu0lJmQeM-8Vo-PzG7PvKz9jfqHNLLlXBnEGJczxQr8EnoVZRHVoH1kSjsAUp1fwkVtiluWbDincWod86o0oYEmLv3Soq08BZ9_E535o8Oi2jaCY9F6UdPnCdW6OU8zWiWUDbnAI"}}, {"reference": "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8", "encrypted": {"v": 1, "kid": "AAECAwQFBgcICQoLDA0ODw", "data": "1ZDHonbgfO43srfwuQFhxsVj7qqpnjVKpX9fFuLlcqB6Qu2OSE9gJs2ACoG_HlODrbX_Ejkbxrk7vnXSKtBv6GX5-5sCNIygdm6CUgao97z5qRF-pmxXG1wmoPmo--5bvyBjF1t-BwOsjjrl3sA-XmEufwQ9ukfXV7lMrjcwNsGT3uyazFSYaA_Vh0R-xyxyi787pRjaJz7qd1lkDmpNlQO5s-pZZ4KDNMsxaXv0o5d8NovVjieWJZxETBkZzGiAtVkQq7RSJa3fBtIckqu6Bmb99wlbXl8Z9NyqHYeeyCgeg6bWiBvq-7L_jcX77ZPNOcKq6T_aK1_9_l5NB5P-u8Md9D8Xe9-fHrZ5FOEIpxONeU-GGZ4psJT4_hP_tT2pYuMXwUriByVe_NCMURSekFmB7XyH-SI6NxoaYjXcTPaaFpy5A7ZejmXz44Yr0bus8lfupVVDnOY9HD92Z6XJXwbYnsByXxTGVXofY3cmwN04YFDWsaFvgHe9IQReJEjkCHPykYs1mSH_acKfSYj04vHVMZansUH3xZvdJ03D133Bub7lzCZSb8fxjA31JsQrsPLuU4YAxqp5NPIRBmD4g56PoBrZQqh4oNwSochS-MLAYloGj-m6ktHg-4RdMopZqggHz7h1e2j_PW9Zr0x4EhqEmsQjCygjzvrKzmPE8e-CQYXSlL2p4OT9L1979DORqb_kTlyDMBGQsoiiAB2x5ZW7HAiTSO5rMuhRbW3N32j666ATPWs36zqs9qvQE3xiCyQqVZLtn8MhnKUsSGhNvuBfR3-fMMEPnywgi9Do2sMBt-rYziVMnbUSvoMzlfAYhvG8IFNgfdBGg3Ds-JOpFSQxV2SeI6JJjIr5e8JOOQPTYGzSaWMj9SJQLAf3KaPjgqvV9I8wwotuK8uZV4Hf4Z-oTIXXsm9vnhjXoQ2_4uBjYBllXwfz3xy_XArGykFCwChPEgdBS04bidSPcBA5kSupDC3NsSBBMW_uGTwxWYP8QnAzSSILgT2HyUxyAmrNwtafOHInunSmJUi31I5Pqzxp1U49tem97Am1e4D83wnxWYCAJ6rjbfHmn2TsbAe4e-ZNRyB3Vqbnnum4BejJDv0dQaeU7RxyBeWiNBizYjE21vhQ1wXYzSWKcU2CXIGOgWLwuUfjUc14NJJ55KGc7Q4UIm6SovBcXOj0NCgYfl3XIPtMaetK-IPB4VHZdl1OwbOM2pMK0WlooFkhT3q2mwBvxlf8YTeLdjEyyuan90WDOpyzRRJPuWJUzQg7zbSKOGb_9-nyCiNmpO55F3Ut9XL-uBOGiEUv8K2Aprzea1uVw0lsK_724lU0xsgcVYwz3HGY-D5Vf6YeX-4wt39Pu-_g90ZKtZT23nqnzNIbDrRin420ZxyAY52d5ZY"}}, {"reference": "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8", "encrypted": {"v": 1, "kid": "AAECAwQFBgcICQoLDA0ODw", "data": "LXbKSmF-LJUJcMHypqRFrS9-LhCidUOVbahQQF0-jjgIHTOZMP7N3MHjIp1yIEqhKVQiYAWTgjybYW6XZT1bQ1ys5EY-xaJjoLZ9LYPhu2K4Izpv8T750KEruSi4zHv91UVV0FQ1Xosc7E4_-qP7rb6_CEBe0z4KANd-c4RVd9KZQggz9Xgd7r0oSLMSJCClZetypdkHlOqdgPO9TjV4Ih-0iF2pTBGd1FYzhgyAAAzBSyRaZzT1L-axcYkyDHJL5agGq0jDOhDq1KVOQ0ayHbcvZ7uS0KFTYd4hEPQY8GZ1RHh9mRlPnrHirTs57mvath-IOqKeOzzEi395vOiMD7DwZ3Flfm8T8CnhDBIfKngeOiU5Gr1U95C62O1jUPAKETiUWsX7eYJpBNaGl-wwXYr157rnJCN-BYbzVYElduDL8q8CHldnvMIQ-Mpr8oe6k77GF3ML_WsVlGaerH3oyyGWakNxUpseorFsblGZTSvyid1ZtJ3eH4EV6n8XYXsiVFFtmxFlG0mLFmS8fUiMNZM7BkCX72m2lUWMpd7oxverVECrIK1R7C2cKZKy8jrz1OcL4sLp6a28W-wS_LZjq5KeSbP3GNTL9dom6LiXZStZKEpVTZgr502XBqtewumvtyxj9oESdxrBYDJxOaAnXDXSytYlre04GBHDowBv8jA7x79PUBXdrKNaN8WyE2z2NU9m6W62pj9jsoBK74U9O_LSMKmsdQopJyazEcRQKgv4w7EcRwmlbWBLHq0lbuT6zr1mJAwmY5ejO6hH6PI2yhyKBlNhgXSRUcY23CiKG_Q82BzqZGTwSlUaS80GdzbllE6DtzfarhY6LfJzsU8wm_XtYsiPt2Hsq9BS2FurlpURndFRyY0npdODZ_pT1x9O0ulLoa_o_-6qWuTQOUoljGAv87pjd4yxIfd4GxALKD-BLgSXQMR87Exn6YuCT6r1SXOUn0W8eWjuO9jCkaiCrYgLvqEdkMRogCpzDo3diQs1mC985__bgs_PBjTQO3yqd4jccle-GLo3PSwNAQIBs-mLbyJXnpUMVuoMnvd_AP0yRpnR7PRfR7gboiKG9YHtnt5EOmIeTwXSrUMM9m7drHalOjoW2gVfMN1msfRqShg3WYZEbMatr15ev9N3V6h0QSW3PRN-kk8o65YCe7Fm2x4Qy0JdSYw8Srb8N7qG0j3BPsSJUqRp4PMhdKTN3YHmwj7ISblujT4oJ1dtrJs_ob9PkH8AQFwImFp8_ER2Jxf1jTj8sV1PYgMFZXWZSxg_98PGS0eVtBdpNlyczMuCmXnv2R6vTgMO9V7TA5FTY_6TkBShT_p_zI6_YK8LCMEvnEnJGqcTiJwFES8UBUR_SfPtNRFs3s_3lnKyzCB1MtpfSxcdpcfpE_jcOmA"}}]
"""#
        return try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[AnyHashable: Any]]
    }
    func testPythonEncryptedPayloadsProduceProfileOnlyTitles() throws {
        let bodies = ["New reply in “Weekend trip”.", "Something went wrong in “Weekend trip”. Open for details.",
                      "“Weekend trip” needs your permission to continue.", "Your agent needs an answer in “Weekend trip” to continue."]
        for (index, fixture) in fixtures.enumerated() {
            let preview = try NotificationPreview.decrypt(userInfo: fixture, secret: secret, now: now)
            XCTAssertEqual(preview.title, "Research")
            XCTAssertEqual(preview.body, bodies[index])
        }
    }
    func testRejectsWrongKeyChangedReferenceTamperingAndExpiry() throws {
        let original = fixtures[0]
        XCTAssertThrowsError(try NotificationPreview.decrypt(userInfo: original, secret: Data(repeating: 7, count: 32), now: now))
        XCTAssertThrowsError(try NotificationPreview.decrypt(userInfo: original, secret: secret, now: now.addingTimeInterval(3601)))
        var changed = original
        changed["reference"] = NotificationPreview.encode(Data(repeating: 7, count: 32))
        XCTAssertThrowsError(try NotificationPreview.decrypt(userInfo: changed, secret: secret, now: now))
        var envelope = original["encrypted"] as! [String: Any]
        var data = try NotificationPreview.decode(envelope["data"] as! String, size: 1052)
        data[100] ^= 1
        envelope["data"] = NotificationPreview.encode(data)
        changed = original; changed["encrypted"] = envelope
        XCTAssertThrowsError(try NotificationPreview.decrypt(userInfo: changed, secret: secret, now: now))
    }
    func testSharedKeychainRegistrationPersistenceAndRemoval() throws {
        let account = "notification-test/" + UUID().uuidString
        defer { NotificationPreview.remove(account: account) }
        let key = try NotificationPreview.key(account: account)
        XCTAssertEqual(try NotificationPreview.key(account: account).keyID, key.keyID)
        let reference = NotificationPreview.encode(Data(repeating: 9, count: 32))
        let content: [String: Any] = ["kind": "approval", "profile": "Research", "conversation": "Weekend trip", "expires": now.timeIntervalSince1970 + 3600]
        let json = try JSONSerialization.data(withJSONObject: content)
        var padded = Data([UInt8(json.count >> 8), UInt8(json.count & 255)]) + json
        padded.append(Data(repeating: 0, count: 1024 - padded.count))
        let aad = Data(("hermes-jr/notification/v1\0" + key.keyID + "\0" + reference).utf8)
        let encrypted = try ChaChaPoly.seal(padded, using: SymmetricKey(data: key.secret), authenticating: aad)
        let payload: [AnyHashable: Any] = ["reference": reference, "encrypted": ["v": 1, "kid": key.keyID, "data": NotificationPreview.encode(encrypted.combined)]]
        XCTAssertEqual(try NotificationPreview.decrypt(userInfo: payload, now: now).title, "Research")
        NotificationPreview.remove(account: account)
        XCTAssertThrowsError(try NotificationPreview.decrypt(userInfo: payload, now: now))
    }

    func testRejectsMalformedPayloads() {
        XCTAssertThrowsError(try NotificationPreview.decrypt(userInfo: [:], secret: secret, now: now))
        var value = fixtures[0]
        value["encrypted"] = ["v": 2, "kid": "x", "data": "x"]
        XCTAssertThrowsError(try NotificationPreview.decrypt(userInfo: value, secret: secret, now: now))
    }
}
