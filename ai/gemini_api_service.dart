// import 'dart:convert';
// import 'package:http/http.dart' as http;

// class GeminiApiService {
//   Future<Map<String, dynamic>> callGemini(Map<String, dynamic> payload) async {
//     // print('CALLING GEMINI WITH PAYLOAD: $payload');
//     const apiKey = "AIzaSyB-apnfrPzP_P6G_hCuWLTRiThrEvHh8Nw";

//     final url = Uri.parse(
//       "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey",
//     );

//     final response = await http.post(
//       url,
//       headers: {"Content-Type": "application/json"},
//       body: jsonEncode({
//         "contents": [
//           {
//             "parts": [
//               {
//                 "text": """
// You are an academic advisor AI.

// IMPORTANT RULES:
// - Return exactly ${payload["maxRecommendations"]} courses only
// - Do NOT exceed ${payload["maxCredits"]} total credits
// - Sort by best predicted success

// Input:
// ${jsonEncode(payload)}
// Return ONLY valid JSON in this exact format:

// {
//   "recommendedCourses": [
//     {
//       "id": "",
//       "title": "",
//       "credits": 0,
//       "success_score": 0,
//       "predicted_gpa": 0,
//       "predicted_letter": "N/A"
//     }
//   ],
//   "totalCreditsRecommended": 0
// }
// """
//               }
//             ]
//           }
//         ]
//       }),
//     );
//     // print("GEMINI RAW RESPONSE: ${response.body}");

//     final data = jsonDecode(response.body);

//     // 🔴 1. تحقق من error أولاً
//     if (data["error"] != null) {
//       print("GEMINI ERROR: ${data["error"]}");
//       return {"recommendations": []};
//     }

//     // 🔴 2. تحقق من candidates
//     final candidates = data["candidates"];

//     if (candidates == null || candidates.isEmpty) {
//       print("EMPTY RESPONSE: ${response.body}");
//       return {"recommendations": []};
//     }

//     final text = candidates[0]["content"]["parts"][0]["text"];

//     try {
//       final clean = text.replaceAll("```json", "").replaceAll("```", "").trim();
//       return jsonDecode(clean);
//     } catch (e) {
//       print("JSON PARSE ERROR: $text");
//       return {"recommendations": []};
//     }
//   }
// }
import 'dart:convert';
import 'package:http/http.dart' as http;

class GeminiApiService {
  Future<Map<String, dynamic>> callGemini(Map<String, dynamic> payload) async {
    const apiKey = "AIzaSyB-apnfrPzP_P6G_hCuWLTRiThrEvHh8Nw";

    final url = Uri.parse(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey",
    );

    final response = await http.post(
      url,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "contents": [
          {
            "parts": [
              {
                "text": """
You are an academic advisor AI.

Your job:
Choose the best courses from availableCourses only.

IMPORTANT RULES:
- Return ONLY courses from availableCourses.
- Do NOT create course IDs.
- Do NOT change schedules.
- Do NOT invent times, rooms, or sections.
- Do NOT exceed ${payload["rules"]?["maxCredits"] ?? payload["maxCredits"]} total credits.
- Return at most ${payload["rules"]?["maxRecommendations"] ?? payload["maxRecommendations"]} courses.
- Prefer courses with higher predicted_gpa.
- Prefer courses with higher success_score.
- Prefer required courses before elective courses.
- Avoid time conflicts based on schedule.
- If you cannot find enough non-conflicting courses, return fewer courses.
- Return ONLY valid JSON. No markdown. No explanation outside JSON.

Input:
${jsonEncode(payload)}

Return ONLY this JSON format:

{
  "recommendedCourses": [
    {
      "id": "COURSE_ID",
      "reason": "short reason"
    }
  ]
}
"""
              }
            ]
          }
        ],
        "generationConfig": {
          "temperature": 0.2,
          "responseMimeType": "application/json"
        }
      }),
    );

    final data = jsonDecode(response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return {"recommendedCourses": []};
    }

    if (data["error"] != null) {
      print("GEMINI ERROR: ${data["error"]}");
      return {"recommendedCourses": []};
    }

    final candidates = data["candidates"];

    if (candidates == null || candidates.isEmpty) {
      print("EMPTY RESPONSE: ${response.body}");
      return {"recommendedCourses": []};
    }

    final text = candidates[0]?["content"]?["parts"]?[0]?["text"];

    if (text == null || text.toString().trim().isEmpty) {
      print("EMPTY TEXT: ${response.body}");
      return {"recommendedCourses": []};
    }

    try {
      final clean = text
          .toString()
          .replaceAll("```json", "")
          .replaceAll("```", "")
          .trim();

      final decoded = jsonDecode(clean);

      if (decoded is Map<String, dynamic>) {
        return decoded;
      }

      return {"recommendedCourses": []};
    } catch (e) {
      print("JSON PARSE ERROR: $text");
      return {"recommendedCourses": []};
    }
  }
}
