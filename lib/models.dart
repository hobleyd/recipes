class EpubPage {
  final String id;
  final String href;
  final String title;
  final String? chapter;

  const EpubPage(
      {required this.id,
      required this.href,
      required this.title,
      this.chapter});

  String get filename => href.split('/').last.replaceAll('.xhtml', '');

  @override
  String toString() => title;
}

class Ingredient {
  String name;
  String imperial;
  String metric;

  Ingredient({this.name = '', this.imperial = '', this.metric = ''});
}

class IngredientSection {
  String label;
  List<Ingredient> ingredients;

  IngredientSection({this.label = '', required this.ingredients});
}

class EpubChapter {
  final String? title; // null = unchaptered group
  final List<EpubPage> pages;

  EpubChapter({this.title, required this.pages});
}

class RecipeData {
  final String title;
  final String description;
  final List<IngredientSection> ingredientSections;
  final String method;
  final String footnote;
  final int anchorNum;
  final int? footnoteNum;

  const RecipeData({
    required this.title,
    required this.description,
    required this.ingredientSections,
    required this.method,
    required this.footnote,
    required this.anchorNum,
    this.footnoteNum,
  });
}
