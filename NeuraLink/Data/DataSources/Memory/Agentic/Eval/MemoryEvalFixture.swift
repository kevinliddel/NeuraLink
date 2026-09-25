//
//  MemoryEvalFixture.swift
//  NeuraLink
//
//  LongMemEval-style fixture for the memory evaluation harness.
//  Each case is a few dated
//  sessions with the facts extraction should yield, optional consolidation
//  actions, and questions tagged by type. `expect` / `avoid` reference fact
//  keys; an observation that lists an expected fact among its sources counts
//  as a hit. Lives in the app target (DEBUG only) so the CI test and the
//  on-device run share one source of truth.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation

#if DEBUG
enum MemoryEvalFixture {

    static let defaultNow = "2026-09-25"

    /// Version bump whenever cases change so reports are comparable.
    static let version = "v1"

    static let json = #"""
    {"cases": [
    {"id": "c01_pet_name", "sessions": [
      {"date": "2026-08-01", "turns": [
        {"role": "user", "text": "Guess what, I finally adopted a cat! His name is Rex."},
        {"role": "assistant", "text": "That's wonderful! Rex is a great name. How is he settling in?"}],
       "facts": [{"key": "rex", "what": "User adopted a cat named Rex.", "when": "2026-08-01", "who": ["user", "Rex"]}]}],
     "questions": [{"type": "single_hop", "q": "what is my cat's name?", "expect": ["rex"]}]},

    {"id": "c02_city", "sessions": [
      {"date": "2026-07-12", "turns": [
        {"role": "user", "text": "I live in Lisbon these days, near the river."},
        {"role": "assistant", "text": "Lisbon by the river sounds lovely."}],
       "facts": [{"key": "lisbon", "what": "User lives in Lisbon, near the river.", "who": ["user", "Lisbon"]}]}],
     "questions": [{"type": "single_hop", "q": "which city do I live in?", "expect": ["lisbon"]}]},

    {"id": "c03_job", "sessions": [
      {"date": "2026-06-03", "turns": [
        {"role": "user", "text": "Work was rough today. Being a pediatric nurse at Mercy Hospital is exhausting."},
        {"role": "assistant", "text": "Caring for kids all day takes a lot out of you. Rest tonight."}],
       "facts": [{"key": "nurse", "what": "User works as a pediatric nurse at Mercy Hospital.", "who": ["user", "Mercy Hospital"]}]}],
     "questions": [{"type": "single_hop", "q": "remind me where I work and what I do", "expect": ["nurse"]}]},

    {"id": "c04_allergy", "sessions": [
      {"date": "2026-05-20", "turns": [
        {"role": "user", "text": "Careful with recipes, I'm allergic to peanuts and shellfish."},
        {"role": "assistant", "text": "Noted, no peanuts or shellfish in anything I suggest."}],
       "facts": [{"key": "allergy", "what": "User is allergic to peanuts and shellfish.", "who": ["user"]}]}],
     "questions": [{"type": "single_hop", "q": "is there anything I can't eat?", "expect": ["allergy"]}]},

    {"id": "c05_sister", "sessions": [
      {"date": "2026-04-09", "turns": [
        {"role": "user", "text": "My sister Manohy is visiting next week, she lives in Antananarivo."},
        {"role": "assistant", "text": "How nice, a visit from Manohy! Are you planning anything special?"}],
       "facts": [{"key": "sister", "what": "User's sister is named Manohy and lives in Antananarivo.", "who": ["user", "Manohy (user's sister)", "Antananarivo"]}]}],
     "questions": [{"type": "single_hop", "q": "what's my sister's name?", "expect": ["sister"]}]},

    {"id": "c06_food", "sessions": [
      {"date": "2026-03-15", "turns": [
        {"role": "user", "text": "Honestly the best meal ever is a bowl of tonkotsu ramen."},
        {"role": "assistant", "text": "Rich and comforting, I get it."}],
       "facts": [{"key": "ramen", "what": "User's favourite meal is tonkotsu ramen.", "who": ["user"]}]}],
     "questions": [{"type": "preference", "q": "what food do I love most?", "expect": ["ramen"]}]},

    {"id": "c07_roommate_job", "sessions": [
      {"date": "2026-02-02", "turns": [
        {"role": "user", "text": "My roommate Emily is a lifesaver, she cooks most nights."},
        {"role": "assistant", "text": "A roommate who cooks is a treasure."}],
       "facts": [{"key": "emily_roommate", "what": "Emily is the user's roommate and cooks most nights.", "who": ["user", "Emily (user's roommate)"]}]},
      {"date": "2026-02-20", "turns": [
        {"role": "user", "text": "Emily just got hired at Sony as a sound engineer!"},
        {"role": "assistant", "text": "Congratulations to Emily, that's a big step."}],
       "facts": [{"key": "emily_sony", "what": "Emily (user's roommate) got hired at Sony as a sound engineer.", "when": "2026-02-20", "who": ["Emily (user's roommate)", "Sony"]}]}],
     "questions": [{"type": "multi_session", "q": "where does my roommate work now?", "expect": ["emily_sony"]}]},

    {"id": "c08_marathon", "sessions": [
      {"date": "2026-01-10", "turns": [
        {"role": "user", "text": "I signed up for the Berlin marathon in September."},
        {"role": "assistant", "text": "Ambitious! How is training going to look?"}],
       "facts": [{"key": "signup", "what": "User signed up for the Berlin marathon taking place in September 2026.", "when": "2026-09", "who": ["user", "Berlin"]}]},
      {"date": "2026-04-22", "turns": [
        {"role": "user", "text": "Long run today, 30 km. My knee is complaining though."},
        {"role": "assistant", "text": "30 km is serious. Be gentle with that knee."}],
       "facts": [{"key": "knee", "what": "User ran 30 km in training and has knee pain.", "when": "2026-04-22", "who": ["user"]}]}],
     "questions": [{"type": "multi_session", "q": "how is my marathon preparation going, any injuries?", "expect": ["knee", "signup"]}]},

    {"id": "c09_car_update", "sessions": [
      {"date": "2025-11-05", "turns": [
        {"role": "user", "text": "I drive a 2019 Honda Civic, nothing fancy."},
        {"role": "assistant", "text": "Reliable car."}],
       "facts": [{"key": "civic", "what": "User owns a 2019 Honda Civic.", "who": ["user", "Honda Civic"]}]},
      {"date": "2026-03-15", "turns": [
        {"role": "user", "text": "Sold the Civic today and picked up a used Tesla Model 3."},
        {"role": "assistant", "text": "Electric life! Enjoy the quiet drive."}],
       "facts": [{"key": "tesla", "what": "User sold the Honda Civic and bought a used Tesla Model 3.", "when": "2026-03-15", "who": ["user", "Tesla Model 3", "Honda Civic"]}]}],
     "consolidation": ["CREATE: User owned a 2019 Honda Civic; sold it on 2026-03-15 and now drives a used Tesla Model 3."],
     "questions": [{"type": "knowledge_update", "q": "what car do I drive?", "expect": ["tesla"], "avoid": ["civic"]}]},

    {"id": "c10_move_update", "sessions": [
      {"date": "2025-09-01", "turns": [
        {"role": "user", "text": "I moved to Tokyo for work last month."},
        {"role": "assistant", "text": "Tokyo! How are you finding it?"}],
       "facts": [{"key": "tokyo", "what": "User moved to Tokyo for work in August 2025.", "when": "2025-08", "who": ["user", "Tokyo"]}]},
      {"date": "2026-06-10", "turns": [
        {"role": "user", "text": "Big news, I relocated to Osaka last week. New apartment in Namba."},
        {"role": "assistant", "text": "Osaka is fun, and Namba never sleeps."}],
       "facts": [{"key": "osaka", "what": "User relocated from Tokyo to Osaka in early June 2026 and lives in Namba.", "when": "2026-06-03", "who": ["user", "Osaka", "Namba", "Tokyo"]}]}],
     "consolidation": ["CREATE: User lived in Tokyo from August 2025; relocated to Osaka (Namba) in June 2026."],
     "questions": [{"type": "knowledge_update", "q": "where do I live now?", "expect": ["osaka"], "avoid": ["tokyo"]}]},

    {"id": "c11_phone_update", "sessions": [
      {"date": "2026-01-15", "turns": [
        {"role": "user", "text": "My phone is an old iPhone 11, battery is dying."},
        {"role": "assistant", "text": "The 11 has had a long life."}],
       "facts": [{"key": "iphone11", "what": "User has an iPhone 11 with a failing battery.", "who": ["user"]}]},
      {"date": "2026-08-30", "turns": [
        {"role": "user", "text": "Upgraded to an iPhone 17 Pro yesterday, the camera is unreal."},
        {"role": "assistant", "text": "Welcome to the new camera era."}],
       "facts": [{"key": "iphone17", "what": "User upgraded to an iPhone 17 Pro on 2026-08-29.", "when": "2026-08-29", "who": ["user"]}]}],
     "questions": [{"type": "knowledge_update", "q": "which phone do I use?", "expect": ["iphone17"], "avoid": ["iphone11"]}]},

    {"id": "c12_diet_update", "sessions": [
      {"date": "2026-02-01", "turns": [
        {"role": "user", "text": "I'm trying to go vegetarian this year."},
        {"role": "assistant", "text": "Great goal, I can suggest veggie recipes."}],
       "facts": [{"key": "veg", "what": "User is trying to become vegetarian in 2026.", "when": "2026", "who": ["user"]}]},
      {"date": "2026-07-04", "turns": [
        {"role": "user", "text": "Gave up on vegetarian, I'm back to eating fish at least. Pescatarian now."},
        {"role": "assistant", "text": "Pescatarian is a solid middle ground."}],
       "facts": [{"key": "pesc", "what": "User stopped being vegetarian and is now pescatarian, eating fish.", "when": "2026-07-04", "who": ["user"]}]}],
     "consolidation": ["CREATE: User tried a vegetarian diet in early 2026, then switched to pescatarian in July 2026."],
     "questions": [{"type": "knowledge_update", "q": "what's my diet these days?", "expect": ["pesc"], "avoid": ["veg"]}]},

    {"id": "c13_last_weekend", "now": "2026-09-25", "sessions": [
      {"date": "2026-09-21", "turns": [
        {"role": "user", "text": "Went hiking in the Alps this weekend with Marco, we did the Tre Cime loop."},
        {"role": "assistant", "text": "The Tre Cime loop is stunning, how were your legs after?"}],
       "facts": [{"key": "hike", "what": "User hiked the Tre Cime loop in the Alps with Marco.", "when": "2026-09-19/2026-09-20", "who": ["user", "Marco", "Alps"]}]},
      {"date": "2026-08-10", "turns": [
        {"role": "user", "text": "Spent the weekend at the beach in Nice with Marco."},
        {"role": "assistant", "text": "Sun and sea, perfect."}],
       "facts": [{"key": "beach", "what": "User spent a weekend at the beach in Nice with Marco.", "when": "2026-08-08/2026-08-09", "who": ["user", "Marco", "Nice"]}]}],
     "questions": [{"type": "temporal", "q": "what did I do last weekend?", "expect": ["hike"], "avoid": ["beach"]}]},

    {"id": "c14_when_adopted", "now": "2026-09-25", "sessions": [
      {"date": "2026-05-02", "turns": [
        {"role": "user", "text": "We brought home a puppy today, a beagle called Mochi."},
        {"role": "assistant", "text": "A beagle puppy! Mochi is going to be a handful."}],
       "facts": [{"key": "mochi", "what": "User brought home a beagle puppy named Mochi.", "when": "2026-05-02", "who": ["user", "Mochi"]}]}],
     "questions": [{"type": "temporal", "q": "what happened in May?", "expect": ["mochi"]}]},

    {"id": "c15_yesterday", "now": "2026-09-25", "sessions": [
      {"date": "2026-09-24", "turns": [
        {"role": "user", "text": "Had my dentist appointment, two fillings, my jaw is numb."},
        {"role": "assistant", "text": "Ouch. Soft food tonight."}],
       "facts": [{"key": "dentist", "what": "User had a dentist appointment and got two fillings.", "when": "2026-09-24", "who": ["user"]}]},
      {"date": "2026-09-10", "turns": [
        {"role": "user", "text": "Had my eye exam, new glasses prescription."},
        {"role": "assistant", "text": "New glasses, new look."}],
       "facts": [{"key": "eyes", "what": "User had an eye exam and received a new glasses prescription.", "when": "2026-09-10", "who": ["user"]}]}],
     "questions": [{"type": "temporal", "q": "what appointment did I have yesterday?", "expect": ["dentist"], "avoid": ["eyes"]}]},

    {"id": "c16_last_month", "now": "2026-09-25", "sessions": [
      {"date": "2026-08-14", "turns": [
        {"role": "user", "text": "Started guitar lessons with a teacher named Paulo."},
        {"role": "assistant", "text": "Music lessons, wonderful. Acoustic or electric?"}],
       "facts": [{"key": "guitar", "what": "User started guitar lessons with a teacher named Paulo.", "when": "2026-08-14", "who": ["user", "Paulo"]}]},
      {"date": "2026-06-14", "turns": [
        {"role": "user", "text": "Started pottery classes on Thursdays."},
        {"role": "assistant", "text": "Pottery is so calming."}],
       "facts": [{"key": "pottery", "what": "User started pottery classes on Thursdays.", "when": "2026-06-14", "who": ["user"]}]}],
     "questions": [{"type": "temporal", "q": "what new hobby did I pick up last month?", "expect": ["guitar"], "avoid": ["pottery"]}]},

    {"id": "c17_trip_year", "now": "2026-09-25", "sessions": [
      {"date": "2025-03-20", "turns": [
        {"role": "user", "text": "Just back from two weeks in Vietnam, Hanoi and Hoi An."},
        {"role": "assistant", "text": "Hoi An lanterns at night are magical."}],
       "facts": [{"key": "vietnam", "what": "User travelled to Vietnam (Hanoi and Hoi An) for two weeks in March 2025.", "when": "2025-03-06/2025-03-20", "who": ["user", "Vietnam", "Hanoi", "Hoi An"]}]},
      {"date": "2026-03-18", "turns": [
        {"role": "user", "text": "Back from a week in Morocco, Marrakech was intense."},
        {"role": "assistant", "text": "The souks are a lot, in the best way."}],
       "facts": [{"key": "morocco", "what": "User travelled to Morocco (Marrakech) for a week in March 2026.", "when": "2026-03-11/2026-03-18", "who": ["user", "Morocco", "Marrakech"]}]}],
     "questions": [{"type": "temporal", "q": "where did I travel in March 2025?", "expect": ["vietnam"], "avoid": ["morocco"]}]},

    {"id": "c18_coffee", "sessions": [
      {"date": "2026-04-01", "turns": [
        {"role": "user", "text": "I can't stand coffee, I'm strictly a green tea person."},
        {"role": "assistant", "text": "Green tea it is, no coffee suggestions from me."}],
       "facts": [{"key": "tea", "what": "User dislikes coffee and prefers green tea.", "who": ["user"]}]}],
     "questions": [{"type": "preference", "q": "should I order you a coffee or something else for me?", "expect": ["tea"]}]},

    {"id": "c19_horror", "sessions": [
      {"date": "2026-05-11", "turns": [
        {"role": "user", "text": "Please never recommend horror movies, I hate jump scares. Give me sci-fi any day."},
        {"role": "assistant", "text": "No horror, plenty of sci-fi. Got it."}],
       "facts": [{"key": "scifi", "what": "User hates horror movies and jump scares, and loves sci-fi films.", "who": ["user"]}]}],
     "questions": [{"type": "preference", "q": "what kind of movie should we watch tonight?", "expect": ["scifi"]}]},

    {"id": "c20_music", "sessions": [
      {"date": "2026-06-21", "turns": [
        {"role": "user", "text": "Lo-fi hip hop is my go-to for studying, and some Bill Evans when I cook."},
        {"role": "assistant", "text": "Lo-fi for focus, Evans for the kitchen. Nice pairing."}],
       "facts": [{"key": "music", "what": "User listens to lo-fi hip hop while studying and Bill Evans while cooking.", "who": ["user", "Bill Evans"]}]}],
     "questions": [{"type": "preference", "q": "play some music I like for studying", "expect": ["music"]}]},

    {"id": "c21_birthday_gift", "sessions": [
      {"date": "2026-03-02", "turns": [
        {"role": "user", "text": "My mum's birthday is on the 14th of April, she's turning 60."},
        {"role": "assistant", "text": "A 60th, that deserves something special."}],
       "facts": [{"key": "mum_bday", "what": "User's mother turns 60 on 2026-04-14.", "when": "2026-04-14", "who": ["user", "user's mother"]}]},
      {"date": "2026-03-20", "turns": [
        {"role": "user", "text": "Mum has been obsessed with orchids lately."},
        {"role": "assistant", "text": "Orchids, noted. That could be a gift idea."}],
       "facts": [{"key": "orchids", "what": "User's mother is very fond of orchids.", "who": ["user's mother"]}]}],
     "questions": [{"type": "multi_session", "q": "any gift ideas for my mum's birthday?", "expect": ["orchids", "mum_bday"]}]},

    {"id": "c22_project_deadline", "sessions": [
      {"date": "2026-07-01", "turns": [
        {"role": "user", "text": "I'm leading the Atlas project at work, a data pipeline rewrite."},
        {"role": "assistant", "text": "Leading a rewrite is a big responsibility."}],
       "facts": [{"key": "atlas", "what": "User leads the Atlas project, a data pipeline rewrite, at work.", "who": ["user", "Atlas"]}]},
      {"date": "2026-08-15", "turns": [
        {"role": "user", "text": "Atlas deadline got moved to October 30th, some breathing room finally."},
        {"role": "assistant", "text": "A later deadline, good news."}],
       "facts": [{"key": "atlas_deadline", "what": "The Atlas project deadline was moved to 2026-10-30.", "when": "2026-10-30", "who": ["Atlas"]}]}],
     "questions": [{"type": "multi_session", "q": "when is the deadline for the project I'm leading?", "expect": ["atlas_deadline"]}]},

    {"id": "c23_japanese", "sessions": [
      {"date": "2026-05-05", "turns": [
        {"role": "user", "text": "私の趣味は週末の釣りです。琵琶湖によく行きます。"},
        {"role": "assistant", "text": "琵琶湖での釣り、いいですね。"}],
       "facts": [{"key": "fishing", "what": "ユーザーの趣味は釣りで、週末によく琵琶湖に行く。", "who": ["user", "琵琶湖"]}]}],
     "questions": [{"type": "single_hop", "q": "私の趣味は何？", "expect": ["fishing"]}]},

    {"id": "c24_kids_school", "sessions": [
      {"date": "2026-04-03", "turns": [
        {"role": "user", "text": "My daughter Lina starts primary school in September."},
        {"role": "assistant", "text": "A big milestone for Lina."}],
       "facts": [{"key": "lina", "what": "User's daughter Lina starts primary school in September 2026.", "when": "2026-09", "who": ["user", "Lina (user's daughter)"]}]},
      {"date": "2026-09-02", "turns": [
        {"role": "user", "text": "First day of school done, Lina loved her teacher Ms. Okafor."},
        {"role": "assistant", "text": "A good teacher makes all the difference."}],
       "facts": [{"key": "okafor", "what": "Lina (user's daughter) had her first day of school and likes her teacher Ms. Okafor.", "when": "2026-09-02", "who": ["Lina (user's daughter)", "Ms. Okafor"]}]}],
     "questions": [{"type": "multi_session", "q": "how is my daughter doing at school?", "expect": ["okafor", "lina"]}]}
    ]}
    """#
}
#endif
