This makes a creamy, mildly spiced paneer butter masala for four, ready in about 40 minutes.

[![Paneer butter masala](https://upload.wikimedia.org/wikipedia/commons/5/5c/Paneer_Makhani_Veggie.jpeg)](https://en.wikipedia.org/wiki/Paneer_makhani)

```openui
root = Card([head, facts, ingredients, method, finish])
head = CardHeader("Paneer butter masala", "Serves 4")
facts = EntityList([{left: "Prep", right: "15 minutes"}, {left: "Cook", right: "25 minutes"}])
ingredients = MarkDownRenderer("### Ingredients\n- 400 g paneer, cubed\n- 4 medium tomatoes, roughly chopped\n- 1 medium onion, sliced\n- 15 cashews\n- 3 tbsp butter, divided\n- 1 tbsp oil\n- 1 bay leaf\n- 1 tbsp ginger-garlic paste\n- 1½ tsp Kashmiri chilli powder\n- 1 tsp coriander powder\n- ½ tsp garam masala\n- 1 tsp kasuri methi, crushed\n- 3 tbsp fresh cream\n- ½–1 tsp sugar, optional\n- Salt to taste\n- ¾–1 cup water")
method = Steps([s1, s2, s3, s4, s5])
s1 = StepsItem("Make the base", "Heat 1 tbsp butter and the oil in a pan. Cook the onion for 3–4 minutes. Add tomatoes and cashews; cook until the tomatoes are soft, about 8 minutes. Cool slightly, then blend smooth with a little water.")
s2 = StepsItem("Build the sauce", "Heat the remaining butter in the pan with the bay leaf. Add ginger-garlic paste and cook for 30 seconds. Lower the heat, add chilli and coriander powders, and stir briefly without burning.")
s3 = StepsItem("Simmer", "Pour in the blended base carefully. Add water and salt, then simmer for 8–10 minutes, stirring occasionally. Add sugar if the tomatoes taste too tangy.")
s4 = StepsItem("Add paneer", "Stir in paneer, garam masala and crushed kasuri methi. Simmer gently for 3–4 minutes; avoid overcooking the paneer.")
s5 = StepsItem("Finish", "Lower the heat, stir in cream and warm through. Taste and adjust salt and water.")
finish = Callout("info", "Serve with", "Naan, roti or jeera rice. For softer paneer, soak the cubes in warm water for 10 minutes before adding them.")
```