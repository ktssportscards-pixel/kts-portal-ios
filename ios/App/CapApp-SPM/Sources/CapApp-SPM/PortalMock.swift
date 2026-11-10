import Foundation

#if DEBUG
// Sample data for previewing the app in the sim (KTS_PREVIEW_MOCK = true): land on
// Home populated with fictional submissions, no backend or login required.
// Compiled out of Release / TestFlight builds. Every value here is made up.
func ktsMockDecode<T: Decodable>(_ json: String) -> T? {
    try? JSONDecoder().decode(T.self, from: Data(json.utf8))
}

// Seller /mine mock — this-week + one past submission, for previewing Home + Review + Past in the sim.
let ktsMockMineJSON = """
[
 {"id":101,"status":"accepted","created_at":"2026-11-05T10:00:00Z","reviewed_at":"2026-11-05T12:00:00Z","counts":{"total":3,"buy":2,"pass":1},"offer_total":580,"items":[
   {"cert":"171234567","grader":"PSA","grade":"10","category":"Pokémon","card_title":"Charizard VMAX Rainbow","cardladder_value":500,"confidence":92,"decision":"BUY","offer_amount":400,"item_status":"accepted","review_state":"approved","image_url":""},
   {"cert":"171234568","grader":"PSA","grade":"9","category":"Pokémon","card_title":"Pikachu Illustrator","cardladder_value":210,"confidence":88,"decision":"BUY","offer_amount":180,"item_status":"pending","review_state":"pending","image_url":""},
   {"cert":"171234569","grader":"PSA","grade":"8","category":"Pokémon","card_title":"Common Energy","cardladder_value":20,"confidence":60,"decision":"PASS","offer_amount":null,"item_status":"rejected","review_state":"refused","image_url":""}
 ]},
 {"id":102,"status":"accepted","created_at":"2026-11-05T09:00:00Z","reviewed_at":"2026-11-05T11:00:00Z","counts":{"total":1,"buy":1,"pass":0},"offer_total":260,"items":[
   {"cert":"171239999","grader":"PSA","grade":"10","category":"Basketball","card_title":"Ja Morant Silver Prizm","cardladder_value":300,"confidence":95,"decision":"BUY","offer_amount":260,"item_status":"accepted","review_state":"approved","image_url":""}
 ]},
 {"id":103,"status":"accepted","created_at":"2026-10-28T10:00:00Z","reviewed_at":"2026-10-28T12:00:00Z","counts":{"total":1,"buy":1,"pass":0},"offer_total":320,"items":[
   {"cert":"170000001","grader":"PSA","grade":"9","category":"Football","card_title":"Patrick Mahomes Prizm","cardladder_value":380,"confidence":90,"decision":"BUY","offer_amount":320,"item_status":"accepted","review_state":"approved","image_url":""}
 ]}
]
"""
#endif
